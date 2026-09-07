-- AnimalUnloadEvent.lua
-- Codec-only override of the base-game AnimalUnloadEvent for the RLMenu world-trailer unload.
--
-- RL identifies animals with a string identity key ("farmId uniqueId country"), not the Int32
-- clusterId the base-game stream signatures expect, so streamWriteInt32(<string>) faults on
-- the wire and the server receives an unresolvable id.
--
-- Serialization only: writeStream and readStream are redefined here; run, validate,
-- newServerToClient and onLoadedRideable stay the live base-game methods, so the server-side
-- spawn logic is unchanged. The override is global - every RLRM unload is string-keyed.

local Log = RmLogging.getLogger("RLRM")

assert(AnimalUnloadEvent ~= nil and AnimalUnloadEvent.run ~= nil,
    "AnimalUnloadEvent override: base-game AnimalUnloadEvent must be loaded before this file (check main.lua SECTION 13b load order)")

--- client -> server: trailer node-object plus the string cluster id (base game writes Int32).
--- server -> client: the reply errorCode, at the unchanged UIntN width.
function AnimalUnloadEvent:writeStream(streamId, connection)
    if connection:getIsServer() then
        NetworkUtil.writeNodeObject(streamId, self.trailer)
        streamWriteString(streamId, tostring(self.clusterId))
        Log:trace("AnimalUnloadEvent:writeStream: client->server clusterId='%s' (string)", tostring(self.clusterId))
    else
        streamWriteUIntN(streamId, self.errorCode, AnimalUnloadEvent.SEND_NUM_BITS)
        Log:trace("AnimalUnloadEvent:writeStream: server->client errorCode=%s", tostring(self.errorCode))
    end
end

--- Mirror of writeStream's direction split, reading the string cluster id. The
--- `self:run(connection)` tail is preserved so the spawn and publish paths stay base-game.
function AnimalUnloadEvent:readStream(streamId, connection)
    if not connection:getIsServer() then
        self.trailer = NetworkUtil.readNodeObject(streamId)
        self.clusterId = streamReadString(streamId)
        Log:trace("AnimalUnloadEvent:readStream: server<-client clusterId='%s' (string)", tostring(self.clusterId))
    else
        self.errorCode = streamReadUIntN(streamId, AnimalUnloadEvent.SEND_NUM_BITS)
        Log:trace("AnimalUnloadEvent:readStream: client<-server errorCode=%s", tostring(self.errorCode))
    end
    self:run(connection)
end

Log:debug("AnimalUnloadEvent: string-clusterId codec override installed (writeStream/readStream)")
