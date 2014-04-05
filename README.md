# geomess-backend

This is a backend software powering a simple geography-based mobile communications application using an API.

Any user can see all the messages sent from the locations in his/her/their proximity (about 76m or 250ft).

This software is written in Lua, uses Redis as a database, and must be used with [OpenResty](https://openresty.org) Nginx distribution.

## Dependencies

If the bundled binary version of the [lua-geohash-int](https://github.com/0xebef/lua-geohash-int) library (compiled for x86_64 Linux) does not work for you, then you should try to compile it by yourself. Please check the project's page for instructions.

The compiled *geohash.so* shared library file must be placed in the *lualib* directory where OpenResty should be configured to load it using the *lua_package_cpath* parameter. Please make sure that all the paths in the [nginx.conf](openresty/conf/nginx.conf) file are correctly set for your environment.

Note: *lua-geohash-int* has a different license than this software, please see the [geohash.so-LICENSE](lualib/geohash.so-LICENSE) file.

## API

The HTTP API has 3 functions:

* POST /register - send the location and register
* POST /messages - send the location and a message
* GET /messages - send the location and get the messages

The server will encode the *answer* in a JSON object, which will have a boolean "result" field. If "result" is `false` then the JSON object will also have a string "msg" field with the error message, and if DEBUG mode is enabled in the code then it might also contain a string field "err" with an extended error message.

## Simulating mobile devices using *cURL* for debugging purposes

### Register 3 user accounts

```
$ curl -d "uuid=ED4D74CE-4E0D-14E4-AE37-44E844202987&name=Susan&longitude=15.44&latitude=66.40" http://localhost:8880/api/v1/register
$ curl -d "uuid=6B4D9462-4E13-14E4-8903-44E844202986&name=Carl&longitude=15.44016&latitude=66.40" http://localhost:8880/api/v1/register
$ curl -d "uuid=AA4C84AE-4E2D-14E4-EEE7-44E844202A89&name=Alan&longitude=15.44&latitude=66.40016" http://localhost:8880/api/v1/register
```

### Send the current location and post a message from Carl's user

```
$ curl -d "uuid=6B4D9462-4E13-14E4-8903-44E844202986&longitude=15.44016&latitude=66.40&message=Hello,%20I%20am%20Carl" http://localhost:8880/api/v1/messages
```

### Send the current location and get the messages list from Susan's user

```
$ curl http://localhost:8880/api/v1/messages?uuid=ED4D74CE-4E0D-14E4-AE37-44E844202987\&longitude=15.44\&latitude=66.40\&newer_than=0
```

Messages list is a an array of objects named "list" within the JSON encoded *answer* object. Each item of "list" contains the following elements:

* "id" - the message id
* "user_id" - the user id of the poster
* "user_name" - the user name of the poster
* "ts" - the timestamp of the post in UTC
* "message" - the message text

## Notes

* This is a little, fun project

* There are no passwords, the only authentication is the UUID token which should be randomly generated and kept on the users' devices upon registration (the server keeps only the SHA256 hash of the UUIDs)

* The messages are ephemeral, they will be available in the server only for half an hour by default

* There is whatsoever no protection from forging locations and scraping

## Project Homepage

https://github.com/0xebef/geomess-backend

## License and Copyright

License: AGPLv3 or later

Copyright (c) 2014, 0xebef
