-- hostServer.lua Version 1.1
-- Central host registry server that distributes hosts.txt via diff updates
-- Sends full update on boot and diffs every change; periodic broadcast every 10 minutes
-- Forge-safe multishell self-launch included

-- ==========================
-- SELF-LAUNCH IN MULTISHELL (Forge-safe)
-- ==========================
if type(multishell) == "table" and type(multishell.getCurrent) == "function" then
    local currentProgram = shell.getRunningProgram()
    if multishell.getCurrent() == 1 then
        multishell.launch(shell, currentProgram)
        return
    end
end

-- ==========================
-- CONFIG
-- ==========================
local modemSide = "back"
local modem = peripheral.wrap(modemSide)
modem.open(1)

local HOSTS_MASTER_FILE = "hosts_master.txt" -- persisted master table
local BROADCAST_INTERVAL = 600 -- 10 minutes in seconds
local serverIPFile = "ip.txt"
local serverIP

-- load or create IP
if not fs.exists(serverIPFile) then
    local f = fs.open(serverIPFile,"w")
    f.writeLine("")
    f.close()
    serverIP = nil
else
    local f = fs.open(serverIPFile,"r")
    serverIP = f.readLine()
    f.close()
    if serverIP == "" then serverIP = nil end
end

-- ==========================
-- MASTER HOST TABLE
-- structure:
-- hosts = {
--   ["name"] = { ip = "10.10.10.2", flags = {"router","game"} },
--   ...
-- }
-- ==========================
local hosts = {}

-- load master file
local function loadMaster()
    hosts = {}
    if fs.exists(HOSTS_MASTER_FILE) then
        local f = fs.open(HOSTS_MASTER_FILE,"r")
        local data = f.readAll()
        f.close()
        if data and data ~= "" then
            local ok, t = pcall(textutils.unserialize, data)
            if ok and type(t) == "table" then hosts = t end
        end
    end
end
loadMaster()

local function saveMaster()
    local f = fs.open(HOSTS_MASTER_FILE,"w")
    f.writeLine(textutils.serialize(hosts))
    f.close()
end

-- create diff between oldHosts and newHosts
local function makeDiff(oldHosts, newHosts)
    local diff = { added = {}, removed = {}, updated = {} }
    -- removed
    for k, v in pairs(oldHosts) do
        if not newHosts[k] then table.insert(diff.removed, k) end
    end
    -- added/updated
    for k, v in pairs(newHosts) do
        if not oldHosts[k] then
            diff.added[k] = v
        else
            -- compare ip and flags
            local old = oldHosts[k]
            local changed = false
            if old.ip ~= v.ip then changed = true end
            -- flags compare
            local of = old.flags or {}
            local nf = v.flags or {}
            if #of ~= #nf then changed = true
            else
                for i=1,#of do if of[i] ~= nf[i] then changed = true; break end end
            end
            if changed then diff.updated[k] = v end
        end
    end
    return diff
end

-- ==========================
-- NETWORK HELPERS
-- ==========================
local seq = 0
local function makeUID()
    seq = seq + 1
    return tostring(os.time()).."-"..tostring(seq)
end

local function broadcastAll(payload)
    local packet = { uid = makeUID(), src = serverIP or "0", dst = "0", ttl = 8, payload = payload }
    modem.transmit(1,1,packet)
end

local function sendDirect(dst, payload)
    local packet = { uid = makeUID(), src = serverIP or "0", dst = dst, ttl = 8, payload = payload }
    modem.transmit(1,1,packet)
end

-- ==========================
-- HANDLERS
-- ==========================
-- On boot broadcast full hosts
local function broadcastFullHosts()
    -- send full table in UPDATE_HOSTS
    local payload = { type = "UPDATE_HOSTS", hosts = hosts }
    broadcastAll(payload)
    print("Broadcasted full hosts to network (boot).")
end

-- send diff to network
local function broadcastDiff(diff)
    if (diff and ((diff.added and next(diff.added)) or (diff.removed and #diff.removed>0) or (diff.updated and next(diff.updated)))) then
        local payload = { type = "HOSTS_DIFF", diff = diff }
        broadcastAll(payload)
        print("Broadcasted hosts diff to network.")
    end
end

-- respond to requesters of full hosts
local function handleRequestHosts(src)
    sendDirect(src, { type = "UPDATE_HOSTS", hosts = hosts })
    print("Sent full hosts to "..src)
end

-- ==========================
-- PACKET RECEIVE LOOP
-- ==========================
local function receiveLoop()
    while true do
        local e, side, ch, reply, message, dist = os.pullEvent("modem_message")
        if type(message) == "table" then
            local payload = message.payload
            if type(payload) ~= "table" then
                print("Invalid payload from "..tostring(message.src))
            else
                if payload.type == "DISCOVER_HOST_SERVER" then
                    -- reply to discovery: HOST_SERVER_HERE
                    local server_ip = serverIP or (hosts and (next(hosts) and (hosts[next(hosts)].ip) or nil) )
                    if server_ip then
                        sendDirect(message.src, { type = "HOST_SERVER_HERE", server_ip = server_ip })
                        print("Replied HOST_SERVER_HERE to "..message.src)
                    end
                elseif payload.type == "REQUEST_HOSTS" then
                    -- direct request for full data
                    handleRequestHosts(message.src)
                else
                    -- ignore other types
                end
            end
        end
    end
end

-- ==========================
-- CLI for management
-- ==========================
local function printHelp()
    print([[HostServer Commands:
  addhost <name> <ip> [flags...]
  delhost <name>
  listhosts
  broadcast
  ip
  setip <ip>
  exit
  help
]])
end

local function cliLoop()
    print("HostServer ready. Type 'help' for commands.")
    while true do
        io.write("> ")
        local line = io.read()
        if not line then break end
        local cmd, rest = line:match("^(%S+)%s*(.*)$")
        if not cmd then cmd = line end
        if cmd == "help" then printHelp()
        elseif cmd == "exit" then return
        elseif cmd == "listhosts" then
            for name, info in pairs(hosts) do
                print(name.." -> "..info.ip.." flags: "..table.concat(info.flags or {}, ","))
            end
        elseif cmd == "addhost" then
            -- parse: addhost name ip [flags...]
            local name, ip, flagsStr = rest:match("^(%S+)%s+(%S+)%s*(.*)$")
            if not name or not ip then print("Usage: addhost <name> <ip> [flags...]")
            else
                local flags = {}
                if flagsStr and flagsStr ~= "" then
                    for f in flagsStr:gmatch("%S+") do table.insert(flags, f) end
                end
                local oldHosts = {}
                for k,v in pairs(hosts) do oldHosts[k] = { ip = v.ip, flags = { table.unpack(v.flags or {}) } } end
                hosts[name] = { ip = ip, flags = flags }
                saveMaster()
                local diff = makeDiff(oldHosts, hosts)
                broadcastDiff(diff)
                print("Added host "..name)
            end
        elseif cmd == "delhost" then
            local name = rest:match("^(%S+)$")
            if not name then print("Usage: delhost <name>")
            else
                if hosts[name] then
                    local oldHosts = {}
                    for k,v in pairs(hosts) do oldHosts[k] = { ip = v.ip, flags = { table.unpack(v.flags or {}) } } end
                    hosts[name] = nil
                    saveMaster()
                    local diff = makeDiff(oldHosts, hosts)
                    broadcastDiff(diff)
                    print("Deleted host "..name)
                else print("No such host: "..name) end
            end
        elseif cmd == "broadcast" then
            broadcastFullHosts()
        elseif cmd == "setip" then
            local ip = rest:match("^(%S+)")
            if ip then
                serverIP = ip
                local f = fs.open(serverIPFile,"w")
                f.writeLine(serverIP)
                f.close()
                print("Server IP set to "..serverIP)
            else print("Usage: setip <ip>") end
        elseif cmd == "ip" then
            print("Server IP: "..tostring(serverIP))
        else
            print("Unknown command. Type 'help'.")
        end
    end
end

-- ==========================
-- BROADCASTER (periodic)
-- ==========================
local function periodicBroadcast()
    -- On boot send full
    broadcastFullHosts()
    -- then loop
    while true do
        os.sleep(BROADCAST_INTERVAL)
        -- send small heartbeat broadcast asking for routers to request diffs? We'll send a light full ping
        broadcastFullHosts()
    end
end

-- ==========================
-- START SERVER
-- ==========================
parallel.waitForAny(receiveLoop, cliLoop, periodicBroadcast)
