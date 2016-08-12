## Caching Proxy

#### Overview

So, it's a reverse proxy, with caching. Is that enough?
  
Ok, so the intention is that it be a reverse proxy which allows caching and easy manipulation of the cache ( purging ), super easy config updates, and fairly granular configuration of cached endpoints.

The proxy does two things, it proxies requests and it caches and serves responses. A target, in this context, is a url that the proxy is configured to proxy requests to. Generally you'll want to set up a catch-all target configuration that does no caching, just proxying requests through to target. In addition to the catch all you'll probably add 1..N cached target configurations.  In the standard scenario, most requests will go proxy directly to the target and a subset of requests will be cached and cached content served to the requestor.

When serving a request that matches a cached target configuration, the cache is ALWAYS served.  In the case that there is no cache, it's built and the caller waits, then it is served.  In the case that the cache exists, it's served to the caller.  In the case that the cache exists and is expired, it's served to the caller and the cache is rebuilt in the background. Requests to a cached target configuration that result in a request making it through to the target ( a cache build or rebuild request ) are singular.  This is to say that for a cached target configuration, only a single request matching a target configuration will ever go through to the target to build or rebuild a cache entry all the rest wait.

#### Configuration

