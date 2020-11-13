#! /usr/bin/env node
/*
const Redis = require("ioredis");
const redis = new Redis(); // uses defaults unless given configuration object

// ioredis supports all Redis commands:
redis.set("foo", "bar"); // returns promise which resolves to string, "OK"

// Or ioredis returns a promise if the last argument isn't a function
redis.get("foo").then(function (result) {
  console.log(result); // Prints "bar"
});

*/

var Memcached = require('memcached');
var memcached = new Memcached('127.0.0.1:11211');

promiseToSet = new Promise((resolve, reject) => {
  memcached.set('itsakey', 'itsvalue', 0, function(err){
    if (err) {
      reject(err);
    } else {
      resolve();
    } 
  });
});

promiseToGet = new Promise((resolve, reject) => {
  memcached.get('itsakey', function(err, value){
    if (err) {
      reject(err);
    } else {
      resolve(value);
    }
  });
});


promiseToSet
  .then(() => promiseToGet)
  .then((value) => console.log(value))
  .then(() => memcached.end());

