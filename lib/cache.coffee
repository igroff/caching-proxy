Promise = require 'bluebird'
fs      = Promise.promisifyAll(require('fs'))
path    = require 'path'
log     = require 'simplog'
lock    = require './file_lock.coffee'

config  = require './config.coffee'
lockMap = {}
tempCounter = 0

tryGetCachedResponse = (cacheKey) ->
  log.debug "tryGetCachedResponse(#{cacheKey})"
  [cacheFilePath, cacheBodyFilePath] = getCacheFilePath cacheKey
  fs.statAsync(cacheBodyFilePath)
  .then () ->
    fs.statAsync(cacheFilePath)
  .then (stats) ->
    log.debug "cacheFilePath #{cacheFilePath}"
    log.debug "cacheBodyFilePath #{cacheBodyFilePath}"
    Promise.all([fs.readFileAsync(cacheFilePath, encoding: 'utf8'), stats])
  .then (r) ->
    data = r[0]
    stats = r[1]
    log.debug "cacheFileData: #{data}"
    lines = data.split('\n')
    cacheResponse = {}
    cacheResponse.statusCode = Number(lines[0])
    cacheResponse.statusMessage = lines[1]
    cacheResponse.headers = JSON.parse(lines[2])
    cacheResponse.createTime = stats.ctime.getTime()
    cacheResponse.body = fs.createReadStream(cacheBodyFilePath)
    Promise.resolve(cacheResponse)
  .catch (e) ->
    log.info "error opening cache file #{cacheFilePath} #{e.message}"
    Promise.resolve(undefined)

getCacheFilePath = (requestInfo) ->
  uniqueIdentifier = "#{process.pid}.#{new Date().getTime}.#{++tempCounter}"
  if typeof(requestInfo) is 'string'
    cacheFilePath = path.join(config.cacheDir, requestInfo)
    cacheFileTempPath = path.join(config.tempDir, "#{requestInfo}.#{uniqueIdentifier}")
  else
    cacheFilePath = path.join(config.cacheDir, requestInfo.cacheKey)
    cacheFileTempPath = path.join(config.tempDir, "#{requestInfo.cacheKey}.#{uniqueIdentifier}")
  return [cacheFilePath, "#{cacheFilePath}.body", cacheFileTempPath, "#{cacheFileTempPath}.body"]

deleteCacheEntry = (cacheKey) ->
  [cacheFilePath] = getCacheFilePath cacheKey
  log.debug "deleting cache file #{cacheFilePath}"
  fs.unlinkAsync cacheFilePath

cacheResponse = (cacheKey, response) ->
  [cacheFilePath, cacheBodyFilePath, cacheFileTempPath, cacheBodyFileTempPath] = getCacheFilePath cacheKey
  log.debug "caching response metadata to #{cacheFilePath}, and body to #{cacheBodyFilePath}"
  metadataStream = fs.createWriteStream(cacheFileTempPath, {flag: 'w+', defaultEncoding: 'utf8'})
  metadataStream.write("#{response.statusCode}\n")
  metadataStream.write("#{response.statusMessage}\n")
  metadataStream.write("#{JSON.stringify response.headers}\n")
  metadataStream.end()
  response.pipe(fs.createWriteStream(cacheBodyFileTempPath, {flat: 'w+', defaultEncoding: 'utf8'}))
  new Promise (resolve, reject) ->
    response.on 'end', () ->
      # once the response is complete, we will have written (piped) out the response to the
      # temp file, all that remains is to move the temp files into place of the 'non temp' 
      # files
      fs.renameAsync(cacheFileTempPath, cacheFilePath)
      .then(() -> fs.renameAsync(cacheBodyFileTempPath, cacheBodyFilePath))
      .then( resolve )
      .catch( reject )

getCacheLock = (cacheKey) ->
  lockPath = path.join(config.lockDir, "#{cacheKey}.lock")
  lockDescriptor = lock.tryAquireLock lockPath
  lockMap[cacheKey] = lockDescriptor if lockDescriptor
  return lockDescriptor

releaseCacheLock = (cacheKey) ->
  lockDescriptor = lockMap[cacheKey]
  if lockDescriptor
    lock.releaseLock lockDescriptor
  else
    log.debug "requested release of key lock #{cacheKey} when it wasn't locked" unless lockDescriptor

module.exports.tryGetCachedResponse = tryGetCachedResponse
module.exports.cacheResponse = cacheResponse
module.exports.getCacheLock = getCacheLock
module.exports.releaseCacheLock = releaseCacheLock
module.exports.deleteCacheEntry = deleteCacheEntry
