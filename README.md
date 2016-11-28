### What?

It's a reverse proxy, that caches. The purpose here is to put something (frequently, if not always)
apps that do heavy lifting such as database access suc that we can, as needed, add caching infront
those access points to enhance performance or hide issues/outages.


### What's it do?

It proxies requests it receives to other locations as it is configured. It proxies both HTTP and Websocket
requests however it only offers caching of HTTP responses. No caching is available for Websocket 'requests',
although proxying is.

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
from a configuration file at start or from an appropriate admin request at runtime. Below is a sample
configuration object:

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
    "route": "/bidb/sys/logShippedReplicaStatus.mustache.*",
    "target": "http://services-internal.glgresearch.com/epiops",
    "maxAgeInMilliseconds": 5000
  },
  {
    "route": "/now",
    "target": "http://jobs.glgresearch.com/PUBLIC",
    "maxAgeInMilliseconds": 5000
  },
  {
    "route": "/price-service-v5",
    "target": "http://services-internal.glgresearch.com",
    "maxAgeInMilliseconds": 5000
  },
  {
    "route": "*",
    "target": "http://localhost:8000",
    "maxAgeInMilliseconds": 0
  }
]
````
