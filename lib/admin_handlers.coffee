log       = require 'simplog'
config    = require './config.coffee'
utils     = require './util'
cache     = require './cache.coffee'

jdumps    = JSON.stringify

handleAdminRequest = (requestInfo, res) ->
  return unless requestInfo.request.__isAdminRequest
  command = requestInfo.request.__adminCommand
  log.debug "handling admin request url #{requestInfo.request.url}, command: #{command}"
  if command is 'delete'
    return handleDeleteRequest(requestInfo, res)
  else if command is "config"
    # just handing back the current config for whatever reason the caller
    # may have need of seeing it
    res.end(jdumps({status: 'ok', config: config}))
  else if command is "target"
    # regexp is purely for our own internal matching, no need to return it
    res.end(jdumps(requestInfo.config))
  else if command is "diagnostic"
    res.end(jdumps(status: 'ok', message: 'ok'))
  else if command is 'saveTargetConfig'
    handleConfigSaveRequest(requestInfo, res)
  else
    res.end(jdumps(status: 'error', message: 'unknown request'))

# this handles a request to save our config, since it can be modified at runtime
# we may want to ( or not want to ) persist any changes to disk so we allow the
# user to decide by invoking this method
handleConfigSaveRequest = (requestInfo, res) ->
  config.saveTargetConfig()
  .then () -> res.end(jdumps(status: 'ok'))
  .catch (e) ->
    log.error "error saving target configuration data\n%s", e
    res.end(jdumps(status: 'error', message: e.message))

# this handles a request to delete a cache entry
handleDeleteRequest = (requestInfo, res) ->
  cache.deleteCacheEntry(requestInfo.cacheKey)
  .then () ->
    res.end(jdumps(status: 'ok', message: 'cache entry removed'))
  .catch (e) ->
    log.error "error removing cache entry\n%s", e
    res.end(jdumps(status: 'error', message: e.message))

# because we want to allow requests to go to the proxy it's self we need a way to allow 
# requests that target the proxy to be identified, these so called 'admin' requests
# will be prefixed with an unreasonable number of forward slashes '/' to lessen the liklihood
# of a conflict with legitemate proxied requests.
#
# Because of the way the proxy code works with both callbacks and global ( response ) events being
# part of the process of handling a proxied request, some of our state is most easily passed around
# via decorating request, as such we will add proprties to the request indicating that the inbound
# request is an admin request, and then we'll remove the admin 'stuff' from the request url so that
# the normal request info can be processed.  This is because admin requests to do things like delete
# cache entries come in as prefix data on the url, for example
# http://proxy_server_host////delete/this/item.html
# is a request to the proxy server ( an admin request ) for it to delete the cached item /this/item.html
# so the portion /this/item.html is a 'legitimate' url, and the ////delete is just decoration to 
# indicate that the request is an 'admin' request, and that deletion is the desired action
getAdminRequestInfo = (request) ->
  # admin requests will start with ////
  return null unless request.url.startsWith('////')
  trimmedUrl = request.url.replace(/^\/\/\/\//, '')
  parts = trimmedUrl.split '/'
  command = parts.shift()
  url = "/#{parts.join('/')}"
  return [command, url]

module.exports.isAdminRequest = (request) -> request.__isAdminRequest
module.exports.requestHandler = handleAdminRequest
module.exports.getAdminRequestInfo = getAdminRequestInfo
