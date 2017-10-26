var express         = require('express');
var morgan          = require('morgan');
var cookieParser    = require('cookie-parser');
var bodyParser      = require('body-parser');
var connect         = require('connect');
var connectTimeout  = require('connect-timeout');
var log             = require('simplog');
var fs              = require('fs');


var app = express();

app.use(connect());
app.use(morgan('combined'));
app.use(cookieParser());
// parse application/x-www-form-urlencoded
//app.use(bodyParser.urlencoded({ extended: false }))
// parse application/json
app.use(bodyParser.raw({type: "application/*"}));
app.use("/", express.static(__dirname + "/site"));
// parse application/vnd.api+json as json
app.use(bodyParser.json({ type: 'application/vnd.api+json' }))


app.all("/echo/*", function (request, response) {
  respondWithThis = {
    body: request.body.toString(),
    queryString: request.query
  };
  response.send(JSON.stringify(respondWithThis, null, 2));
});

app.all("/long_sleep/*", function(request, response){
  function respond(){
    response.status(200).send("DONE");
  }
  setTimeout(respond, 124000);
});
app.all("/sleep/*", function(request, response){
  function respond(){
    response.status(200).send("DONE");
  }
  setTimeout(respond, 5000);
});

app.all("/echo-something/only-with-this-path", function (request, response){
  response.status(200).send("this is a response to be expected");
});

app.all("/now", function(request, response){
  response.status(200).send(new Date().getTime().toString());
});

app.all("/now-slow", function(request, response){
  setTimeout(function(){
    response.status(200).send(new Date().getTime().toString());
  }, 1000);
});

app.all("/modal", function(request, response){
  if (fs.existsSync(__dirname + '/show_error')){
    response.status(500).send(new Date().getTime().toString());
  } else {
    response.status(200).send(new Date().getTime().toString());
  }
});

app.all("/destroy", function(request, response){
  response.destroy();
});

listenPort = process.env.PORT || 8000;
log.info("starting app " + process.env.APP_NAME);
log.info("listening on " + listenPort);
app.listen(listenPort).setTimeout(300 * 1000);
