Promise       = require 'bluebird'
fs            = Promise.promisifyAll(require('fs'))
path          = require 'path'
log           = require 'simplog'
lock          = Promise.promisifyAll(require('./file_lock.coffee'))
EventEmitter  = require 'events'

config  = require './config.coffee'
tempCounter = 0
cacheEventEmitter = new EventEmitter()
# an arbitrary, but larger than default, max listener count
# It really shouldn't ever be hit but I kind of feel like we want to know if we
# have a shitload of cache waiters backed up and this 'll blow it up so we
# can see
cacheEventEmitter.setMaxListeners(1000)

tryGetCachedResponse = (cacheKey) ->
  log.debug "tryGetCachedResponse(#{cacheKey})"
  [cacheFilePath, cacheBodyFilePath] = getCacheFilePath cacheKey
  fs.statAsync(cacheFilePath)
  .then () ->
    fs.statAsync(cacheBodyFilePath)
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
  uniqueIdentifier = "#{process.pid}.#{new Date().getTime()}.#{++tempCounter}"
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
  fs.unlinkAsync(cacheFilePath)
  .catch( (e) ->
    # it's cool if we get asked to delete a chache entry that isn't there but if we get
    # anything else, we want it to bubble up
    if e.message.indexOf("ENOENT") is -1
      throw e
  )

cacheResponse = (cacheKey, response) ->
  [cacheFilePath, cacheBodyFilePath, cacheFileTempPath, cacheBodyFileTempPath] = getCacheFilePath cacheKey
  log.debug "caching response metadata to #{cacheFilePath}, and body to #{cacheBodyFilePath}"
  log.debug "%s %s %s %s", cacheFilePath, cacheBodyFilePath, cacheFileTempPath, cacheBodyFileTempPath
  metadataStream = fs.createWriteStream(cacheFileTempPath, {flag: 'w', defaultEncoding: 'utf8'})
  promiseForMetadataFileToEndWrite = new Promise (resolve, reject) ->
    metadataStream.on 'finish', resolve
    metadataStream.on 'error', reject
  metadataStream.write("#{response.statusCode}\n")
  metadataStream.write("#{response.statusMessage}\n")
  metadataStream.write("#{JSON.stringify response.headers}\n")
  metadataStream.end()
  response.pipe(fs.createWriteStream(cacheBodyFileTempPath, {flat: 'w', defaultEncoding: 'utf8'}))
  promiseForResponseToEnd = new Promise (resolve, reject) ->
    response.on 'end', resolve
    response.on 'error', reject
  new Promise (resolve, reject) ->
    promiseForMetadataFileToEndWrite
    .then promiseForResponseToEnd
    .then () ->
        # once the response is complete, we will have written (piped) out the response to the
        # temp file, all that remains is to move the temp files into place of the 'non temp' 
        # files
        fs.renameAsync(cacheFileTempPath, cacheFilePath)
        .then(() -> fs.renameAsync(cacheBodyFileTempPath, cacheBodyFilePath))
        .then( () -> cacheEventEmitter.emit "#{cacheKey}" )
        .then( resolve )
        .catch( (e) ->
          cacheEventEmitter.emit "#{cacheKey}", e
          reject(e)
        )

getCacheLock = (cacheKey) ->
  lockPath = path.join(config.lockDir, "#{cacheKey}.lock")
  return lock.tryAquireLock lockPath

promiseToGetCacheLock = (cacheKey) ->
  new Promise (resolve, reject) ->
    lockPath = path.join(config.lockDir, "#{cacheKey}.lock")
    lock.tryAquireLockAsync(lockPath)
    .then resolve
    .catch reject

releaseCacheLock = (lockDescriptor) ->
  if lockDescriptor
    lock.releaseLock lockDescriptor
  else
    log.debug "requested release of key lock #{cacheKey} when it wasn't locked" unless lockDescriptor

promiseToReleaseCacheLock = (lockDescriptor) ->
  new Promise (resolve, reject) ->
    lock.releaseLockAsync(lockDescriptor)
    .then resolve
    .catch reject

module.exports.tryGetCachedResponse = tryGetCachedResponse
module.exports.cacheResponse = cacheResponse
module.exports.getCacheLock = getCacheLock
module.exports.releaseCacheLock = releaseCacheLock
module.exports.promiseToGetCacheLock = promiseToGetCacheLock
module.exports.promiseToReleaseCacheLock = promiseToReleaseCacheLock
module.exports.deleteCacheEntry = deleteCacheEntry
module.exports.events = cacheEventEmitter
