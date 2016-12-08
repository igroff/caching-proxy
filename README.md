### What?

It's a reverse proxy, that caches. The purpose here is to put something (frequently, if not always)
apps that do heavy lifting such as database access suc that we can, as needed, add caching infront
those access points to enhance performance or hide issues/outages.

### What's it do?

It proxies requests it receives to other locations as it is configured. It proxies both HTTP and Websocket
requests however it only offers caching of HTTP responses. No caching is available for Websocket 'requests',
although proxying is.

##### More Detail on Caching Behaviors

The goal of this piece of software is to serve cached responses, and do so in such a way as to make that behavior easily configurable and manageable. To do this it allows runtime configuration updates, and defaults to serving cached responses in all situations. Here's a little more detail about this

*using maxAgeInMilliseconds*

The details of the configuration are below, but in the case of using this value the general behavior is as follows

````
  handleInboundRequest
    if there is a cached response, return it to the requestor immediately
    //continue on 'in the background'
    if the cache is expired
      if cache lock can be obtained
        rebuild cache
      else
        // cache is already being rebuilt by another request
        done
````


### Definitions

* caching proxy - an instance this piece of software managing access to some other service, frequently 
  referred to as being 'in front of' another service.
* target config - a configuration of a URL to which a request will be proxied. Target configurations (configs)
  define the URL to which the request will be ultimately sent, as well as an caching behavior desired.
* admin request - There are various administrative actions that can be take via the HTTP interface
  to the caching proxy itself. Most notably these are configuration and cache deletion related actions.
  A request for one of these actions is called an admin request.


### Configuration

Configuration of the proxy is managed via a single array of Javascript Objects and is read either 
from a configuration file ( stored as valid JSON ) at start or from an appropriate admin request
at runtime. Below is a sample configuration object:

````
[
  {
    "route": "/short-lived",
    "target": "http://localhost:8000/now",
    "maxAgeInMilliseconds": 10000,
    "doNotServeStaleCache": true
  },
  {
    "route": "/short-lived-allow-stale",
    "target": "http://localhost:8000/now",
    "maxAgeInMilliseconds": 10000
  },
  {
    "route": "/expire-at-absolute-time-of-day",
    "target": "http://localhost:8000/now",
    "dayRelativeExpirationTimeInMilliseconds": 300000   
  },
  {
    "route": "/now",
    "target": "http://localhost:8000/now",
    "maxAgeInMilliseconds": 5000
  },
  {
    "route": "*",
    "target": "http://localhost:8000",
    "maxAgeInMilliseconds": 0
  }
]
````

#### Target Configuration

A single target config has a couple manditory configuration elements and a few optional ones.

##### Required
* route - This is essentially just a regular expression, with some small amount of magic. The expression
  is treated as if you started it with a '^' and allows the specification of a single asterisk as
  a shortcut for any match at all. This value is what is tested against the inbound request path 
  if it matches, the target config is used to define behavior of the response.
* target - The fully qualified URL of the destination to which the request will be proxied.

##### One *OR* The Other Must Be Present
* dayRelativeExpirationTimeInMilliseconds - The ABSOLUTE time in milleseconds AFTER 12:00 AM that a cached item
  will expire. For example if you want a cached response to be refreshed daily at 1:00 AM you would set this
  value to 3600000, which is the number of milliseconds past 12:00 AM 1:00AM 'is'.
* maxAgeInMilliseconds - The maximum duration (in milliseconds )after the creation of a cached response
  it will be considered valid. If this value is set to any number less than 1, no caching is performed and 
  the request is simply proxied through to the target.

##### Optional
* serveStaleCache - This is an optional boolean configuration value defaulting to true. If set to false
  an expired cached value will NOT be served, instead the first request for the associated expired cached item
  will cause it to be recached and the 'new' response served to the caller.
* sendPathWithProxiedRequest - Determines if the request to the target will include the full original
  path of the request appended to the target URL. If false, the path will not be sent to the target and the target URL
  will be the 'full URL' of the proxied request.
