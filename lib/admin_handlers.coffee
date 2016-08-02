log       = require 'simplog'
config    = require './config.coffee'
utils     = require './util'

jdumps    = JSON.stringify

handleAdminRequest = (request, res) ->
  trimmedUrl = request.url.replace(/^\/\/\/\//, '')
  parts = trimmedUrl.split '/'
  command = parts.shift()
  trimmedUrl = "/#{parts.join('/')}"
  log.debug "handling admin request url #{trimmedUrl}, command: #{command}, working url: #{trimmedUrl}"
  requestInfo = utils.buildRequestInfoFor(request, trimmedUrl)
  if requestInfo.method is "DELETE"
    return handleDeleteRequest(requestInfo, res)
  else if command is 'delete'
    return handleDeleteRequest(requestInfo, res)
  else if command is "config"
    # just handing back the current config for whatever reason the caller
    # may have need of seeing it
    res.end(jdumps({status: 'ok', config: config}))
  else if command is "target"
    # regexp is purely for our own internal matching, no need to return it
    delete(requestInfo.config['regexp'])
    res.end(jdumps(requestInfo.config))
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

# just to attempt to not conflict with legit proxy requests, but also allow
# for access to the proxy server configuration itself, we prefix any requests
# to the proxy server itself with ////
isAdminRequest = (request) ->
  return request.url.startsWith('////')

module.exports.isAdminRequest = isAdminRequest
module.exports.requestHandler = handleAdminRequest
