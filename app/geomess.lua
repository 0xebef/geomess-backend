-- geomess-backend
--
-- This is a backend software powering a simple geography-based mobile
-- communications application using an API.
--
-- Please read the README.md for more information
--
-- License: AGPLv3 or later
--
-- Copyright (c) 2014, 0xebef

local redis = require "resty.redis"
local str = require "resty.string"
local sha256 = require "resty.sha256"
local cjson = require "cjson"
local geohash = require "geohash"
local os = require "os"
local math = require "math"

-- when set to a non-zero value the error messages will include more information
local DEBUG = 0

-- redis connection
local red = nil

-- geographic constants
local MERCATOR_MAX = 20037726.37
local MERCATOR_MIN = -20037726.37
local LONGITUDE_MAX = 180.0
local LONGITUDE_MIN = -180.0
local LATITUDE_MAX = 90.0
local LATITUDE_MIN = -90.0

-- limits
local UUID_LENGTH = 36
local USER_NAME_LENGTH_MAX = 128
local COORDINATE_LENGTH_MAX = 64
local MESSAGE_EXPIRE_TIME = 1800
local MESSAGE_LENGTH_MAX = 4096

-- geohash proximity search is based on this document:
-- https://github.com/yinqiwen/ardb/wiki/Spatial-Index
local GEOHASH_HIGHRES_STEPS = 26
local GEOHASH_LOWRES_STEPS = 19 -- for 76.4378m proximity
local GEOHASH_BITS_DIFF = GEOHASH_HIGHRES_STEPS * 2 - GEOHASH_LOWRES_STEPS * 2
local GEOHASH_NORTH = 0
local GEOHASH_EAST = 1
local GEOHASH_WEST = 2
local GEOHASH_SOUTH = 3
local GEOHASH_SOUTH_WEST = 4
local GEOHASH_SOUTH_EAST = 5
local GEOHASH_NORTH_WEST = 6
local GEOHASH_NORTH_EAST = 7
local GEOHASH_DIRECTIONS_COUNT = 8
local GEOHASH_NEIGHBORS_COUNT = 2 * GEOHASH_DIRECTIONS_COUNT

-- print debug messages
local function my_debug(msg)
    if DEBUG then
        ngx.print(msg)
    end
end

-- left shift emulation
local function lshift(n, b)
    return n * math.pow(2, b)
end

-- calculate the distance between two locations
local function dist(lon1, lat1, lon2, lat2)
    local dlon = math.rad(lon2 - lon1)
    local dlat = math.rad(lat2 - lat1)
    local sin_dlat_half = math.sin(dlat / 2.0)
    local sin_dlon_half = math.sin(dlon / 2.0)
    local a = (sin_dlat_half * sin_dlat_half) +
        math.cos(math.rad(lat1)) * math.cos(math.rad(lat2)) * (sin_dlon_half * sin_dlon_half)

    return 6367 * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
end

-- convert the EPSG4326 coordinate system into Mercator coordinate system
local function epsg4326_to_mercator(lon, lat)
    local x = lon * MERCATOR_MAX / 180
    local y = math.log(math.tan((90 + lat) * math.pi / 360)) / (math.pi / 180)
    y = y * MERCATOR_MAX / 180
    return x, y
end

-- generate a user ID using Redis
local function user_id_gen()
    local res, err = red:incr("user_id_generator")
    if err then
        return false, "failed to generate a user id"
    end

    return res, nil
end

-- generate a message ID using Redis
local function message_id_gen()
    local res, err = red:incr("message_id_generator")
    if err then
        return false, "failed to generate a message id"
    end

    return res, nil
end

-- compare function for sorting messages by time
local function messages_sorter(t1, t2)
    return t1.ts > t2.ts
end

-- get the proximity ranges
-- geohash proximity search is based on this document:
-- https://github.com/yinqiwen/ardb/wiki/Spatial-Index
local function get_proximity_ranges(geohash_lowres_value)
    local geo_res_neighbors, err = geohash.get_neighbors(
        geohash_lowres_value, GEOHASH_LOWRES_STEPS)
    if not geo_res_neighbors then
        return nil, err
    elseif #geo_res_neighbors ~= GEOHASH_NEIGHBORS_COUNT then
        return nil, "unexpected count of neighbors"
    else
        geo_res_neighbors[GEOHASH_NEIGHBORS_COUNT + 1] = geohash_lowres_value
        local i
        for i = 1, GEOHASH_NEIGHBORS_COUNT + 1, 2 do
            geo_res_neighbors[i + 1] = geo_res_neighbors[i] + 1
            geo_res_neighbors[i] = lshift(geo_res_neighbors[i], GEOHASH_BITS_DIFF)
            geo_res_neighbors[i + 1] = lshift(geo_res_neighbors[i + 1], GEOHASH_BITS_DIFF)
        end
    end

    return geo_res_neighbors, nil
end

-- post a message
local function save_message(hash_hex, geohash_highres_value, msg)
    message_id, err = message_id_gen()
    if err then
        return nil, err
    end

    local res, err = red:hmget("users:" .. hash_hex, "id", "name")
    if err then
        return nil, err
    end

    local json = {
        ["id"] = message_id,
        ["user_id"] = res[1],
        ["user_name"] = res[2],
        ["ts"] = os.time(os.date("!*t", os.time())),
        ["message"] = msg
    }

    local message_key = "messages:" .. message_id
    local res, err = red:set(message_key, cjson.encode(json))
    if err then
        return nil, err
    end

    red:expire(message_key, MESSAGE_EXPIRE_TIME)

    local res, err = red:zadd("messages", geohash_highres_value, message_id)
    if err then
        return nil, err
    end

    return true, nil
end

-- load messages based on the user's location and their newest message's timestamp
local function load_messages(geohash_highres_value, geohash_lowres_value, newer_than)
    local proximity, err = get_proximity_ranges(geohash_lowres_value)
    if err then
        return nil, err
    end

    local messages = {}
    local found_messages = {}
    local n = 0

    local i
    for i = 1, #proximity - 1, 2 do
        local res, err = red:zrangebyscore("messages", proximity[i], proximity[i + 1])
        if err then
            return nil, err
        end
        if #res > 0 then
            local j
            for j = 1, #res, 1 do
                if res[j] and not found_messages[res[j]] then
                    found_messages[res[j]] = true

                    local message_key = "messages:" .. res[j]
                    local res, err = red:get(message_key)
                    if err then
                        return nil, err
                    end
                    if res then
                        local message = cjson.decode(res)
                        if message.ts > newer_than then
                            n = n + 1
                            messages[n] = {
                                ["id"] = message.id,
                                ["user_id"] = message.user_id,
                                ["user_name"] = message.user_name,
                                ["ts"] = message.ts,
                                ["message"] = message.message,
                            }
                        end
                    else
                        red:zrem("messages", res[j])
                    end
                end
            end
        end
    end

    table.sort(messages, messages_sorter)

    return messages, nil
end

-- generate a erroneous JSON message
local function fail(json, err)
    json.result = false
    if DEBUG and err then
        json.err = err
    end
    ngx.print(cjson.encode(json))
end

-- generate a successful JSON message
local function success(json)
    json.result = true
    ngx.print(cjson.encode(json))
end

-- nothing in the index route by default
local function index_get()
    fail({["msg"] = "invalid input"})

    return ngx.HTTP_OK
end

-- controller for the registration API request
local function register_post()
    local args = ngx.req.get_post_args(10)

    if not args.uuid or args.uuid == "" then
        fail({["msg"] = "uuid is expected"})
        return ngx.HTTP_OK
    end
    if not args.name or args.name == "" then
        fail({["msg"] = "name is expected"})
        return ngx.HTTP_OK
    end
    if not args.longitude or args.longitude == "" then
        fail({["msg"] = "longitude is expected"})
        return ngx.HTTP_OK
    end
    if not args.latitude or args.latitude == "" then
        fail({["msg"] = "latitude is expected"})
        return ngx.HTTP_OK
    end

    if type(args.uuid) ~= "string" or type(args.name) ~= "string" or
        type(args.longitude) ~= "string" or type(args.latitude) ~= "string"
    then
        fail({["msg"] = "invalid input received"})
        return ngx.HTTP_OK
    end

    if string.len(args.uuid) ~= UUID_LENGTH then
        fail({["msg"] = "the uuid is invalid"})
        return ngx.HTTP_OK
    end
    if string.len(args.name) > USER_NAME_LENGTH_MAX then
        fail({["msg"] = "the name is too long"})
        return ngx.HTTP_OK
    end
    if string.len(args.longitude) > COORDINATE_LENGTH_MAX then
        fail({["msg"] = "the longitude is invalid"})
        return ngx.HTTP_OK
    end
    if string.len(args.latitude) > COORDINATE_LENGTH_MAX then
        fail({["msg"] = "the latitude is invalid"})
        return ngx.HTTP_OK
    end

    args.longitude = tonumber(args.longitude)
    args.latitude = tonumber(args.latitude)

    if args.longitude < LONGITUDE_MIN or args.longitude > LONGITUDE_MAX or
        args.latitude < LATITUDE_MIN or args.latitude > LATITUDE_MAX
    then
        fail({["msg"] = "invalid coordinates"})
        return ngx.HTTP_OK
    end

    args.longitude, args.latitude = epsg4326_to_mercator(args.longitude, args.latitude)

    local geo_res_high, err = geohash.encode(
        MERCATOR_MAX, MERCATOR_MIN, MERCATOR_MAX, MERCATOR_MIN,
        args.latitude, args.longitude, GEOHASH_HIGHRES_STEPS
    )
    if not geo_res_high then
        fail({["msg"] = "system error, please try later"}, err)
        return ngx.HTTP_OK
    end

    user_id, err = user_id_gen()
    if err then
        fail({["msg"] = "system error, please try later"}, err)
        return ngx.HTTP_OK
    end

    local hash = sha256:new()
    hash:update(args.uuid)
    local hash_hex = str.to_hex(hash:final())

    local res, err = red:hmset(
        "users:" .. hash_hex,
        "id", user_id,
        "name", args.name
    )
    if err then
        fail({["msg"] = "system error, please try later"}, err)
        return ngx.HTTP_OK
    end

    success({})

    return ngx.HTTP_OK
end

-- controller for the post message API request
local function messages_post()
    local args = ngx.req.get_post_args(10)

    if not args.uuid or args.uuid == "" then
        fail({["msg"] = "uuid is expected"})
        return ngx.HTTP_OK
    end
    if not args.longitude or args.longitude == "" then
        fail({["msg"] = "longitude is expected"})
        return ngx.HTTP_OK
    end
    if not args.latitude or args.latitude == "" then
        fail({["msg"] = "latitude is expected"})
        return ngx.HTTP_OK
    end
    if not args.message or args.message == "" then
        fail({["msg"] = "message is expected"})
        return ngx.HTTP_OK
    end

    if type(args.uuid) ~= "string" or
        type(args.longitude) ~= "string" or
        type(args.latitude) ~= "string" or
        type(args.message) ~= "string"
    then
        fail({["msg"] = "invalid input received"})
        return ngx.HTTP_OK
    end

    if string.len(args.uuid) ~= UUID_LENGTH then
        fail({["msg"] = "the uuid is invalid"})
        return ngx.HTTP_OK
    end
    if string.len(args.longitude) > COORDINATE_LENGTH_MAX then
        fail({["msg"] = "the longitude is invalid"})
        return ngx.HTTP_OK
    end
    if string.len(args.latitude) > COORDINATE_LENGTH_MAX then
        fail({["msg"] = "the latitude is invalid"})
        return ngx.HTTP_OK
    end
    if string.len(args.message) > MESSAGE_LENGTH_MAX then
        fail({["msg"] = "the message is too long"})
        return ngx.HTTP_OK
    end

    local hash = sha256:new()
    hash:update(args.uuid)
    local hash_hex = str.to_hex(hash:final())

    local res, err = red:exists("users:" .. hash_hex)
    if err then
        fail({["msg"] = "system error, please try later"}, err)
        return ngx.HTTP_OK
    end

    if not res or res == 0 then
        fail({["msg"] = "you are not registered"})
        return ngx.HTTP_OK
    end

    args.longitude = tonumber(args.longitude)
    args.latitude = tonumber(args.latitude)

    if args.longitude < LONGITUDE_MIN or args.longitude > LONGITUDE_MAX or
        args.latitude < LATITUDE_MIN or args.latitude > LATITUDE_MAX
    then
        fail({["msg"] = "invalid coordinates"})
        return ngx.HTTP_OK
    end

    args.longitude, args.latitude = epsg4326_to_mercator(args.longitude, args.latitude)

    local geo_res_high, err = geohash.encode(
        MERCATOR_MAX, MERCATOR_MIN, MERCATOR_MAX, MERCATOR_MIN,
        args.latitude, args.longitude, GEOHASH_HIGHRES_STEPS
    )
    if not geo_res_high then
        fail({["msg"] = "system error, please try later"}, err)
        return ngx.HTTP_OK
    end

    save_message(hash_hex, geo_res_high[1], args.message)

    success({})

    return ngx.HTTP_OK
end

-- controller for the get messages API request
local function messages_get()
    local args = ngx.req.get_uri_args(10)

    if not args.uuid or args.uuid == "" then
        fail({["msg"] = "uuid is expected"})
        return ngx.HTTP_OK
    end
    if not args.longitude or args.longitude == "" then
        fail({["msg"] = "longitude is expected"})
        return ngx.HTTP_OK
    end
    if not args.latitude or args.latitude == "" then
        fail({["msg"] = "latitude is expected"})
        return ngx.HTTP_OK
    end
    if not args.newer_than then
        fail({["msg"] = "newer than value is expected"})
        return ngx.HTTP_OK
    end

    if type(args.uuid) ~= "string" or
        type(args.longitude) ~= "string" or
        type(args.latitude) ~= "string" or
        type(args.newer_than) ~= "string"
    then
        fail({["msg"] = "invalid input received"})
        return ngx.HTTP_OK
    end

    if string.len(args.uuid) ~= UUID_LENGTH then
        fail({["msg"] = "the uuid is invalid"})
        return ngx.HTTP_OK
    end
    if string.len(args.longitude) > COORDINATE_LENGTH_MAX then
        fail({["msg"] = "the longitude is invalid"})
        return ngx.HTTP_OK
    end
    if string.len(args.latitude) > COORDINATE_LENGTH_MAX then
        fail({["msg"] = "the latitude is invalid"})
        return ngx.HTTP_OK
    end

    local hash = sha256:new()
    hash:update(args.uuid)
    local hash_hex = str.to_hex(hash:final())

    local res, err = red:exists("users:" .. hash_hex)
    if err then
        fail({["msg"] = "system error, please try later"}, err)
        return ngx.HTTP_OK
    end

    if not res or res == 0 then
        fail({["msg"] = "you are not registered"})
        return ngx.HTTP_OK
    end

    args.longitude = tonumber(args.longitude)
    args.latitude = tonumber(args.latitude)

    if args.longitude < LONGITUDE_MIN or args.longitude > LONGITUDE_MAX or
        args.latitude < LATITUDE_MIN or args.latitude > LATITUDE_MAX
    then
        fail({["msg"] = "invalid coordinates"})
        return ngx.HTTP_OK
    end

    args.longitude, args.latitude = epsg4326_to_mercator(args.longitude, args.latitude)

    local geo_res_high, err = geohash.encode(
        MERCATOR_MAX, MERCATOR_MIN, MERCATOR_MAX, MERCATOR_MIN,
        args.latitude, args.longitude, GEOHASH_HIGHRES_STEPS
    )
    if not geo_res_high then
        fail({["msg"] = "system error, please try later"}, err)
        return ngx.HTTP_OK
    end

    local geo_res_low, err = geohash.encode(
        MERCATOR_MAX, MERCATOR_MIN, MERCATOR_MAX, MERCATOR_MIN,
        args.latitude, args.longitude, GEOHASH_LOWRES_STEPS
    )
    if not geo_res_low then
        fail({["msg"] = "system error, please try later"}, err)
        return ngx.HTTP_OK
    end

    local messages_list, err = load_messages(geo_res_high[1], geo_res_low[1], tonumber(args.newer_than))
    if err then
        fail({["msg"] = "system error, please try later"}, err)
        return ngx.HTTP_OK
    end

    success({["list"] = messages_list})

    return ngx.HTTP_OK
end

-- initialize the Redis database connection
local function db_init()
    red = redis:new()
    red:set_timeout(1000)
    local ok, err = red:connect("127.0.0.1", 6379)
    if not ok then
        my_debug("failed to connect: ", err)
        return
    end
end

-- deinitialize the Redis database connection
local function db_deinit()
    local ok, err = red:set_keepalive(10000, 1000)
    if not ok then
        my_debug("failed to set keepalive: ", err)
        return
    end
end

-- the routes list
local routes = {
    ["GET"] = {
        ["/api/v1"] = index_get,
        ["/api/v1/messages"] = messages_get,
    },
    ["POST"] = {
        ["/api/v1/register"] = register_post,
        ["/api/v1/messages"] = messages_post,
    }
}

-- default content type
ngx.header.content_type = "application/json";

-- get the request's http method
local method = ngx.req.get_method()

-- find the method and route pair in the routes list
if routes[method] then
    local pattern, view
    for pattern, view in pairs(routes[method]) do
        if ngx.var.uri == pattern then
            db_init()
            local view_exit = view() or ngx.HTTP_OK
            db_deinit()
            ngx.exit(view_exit)
        end
    end
end

-- if the request was not recognized throw a "not found" error
ngx.exit(ngx.HTTP_NOT_FOUND)
