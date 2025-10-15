-- client.lua Version 1.4
-- CC:Tweaked wired client for IP router & server systems
-- Supports hostname keywords, HELLO_REPLY only, secure plaintext file transfer, standardized IP file
-- Added Forge-safe multishell self-launch and host update handling with tag searching

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
-- CONFIG & SETUP
-- ==========================
local modemSide = "back"
local modem = peripheral.wrap(modemSide)
modem.open(1)

local IP_FILE = "ip.txt"
local HOSTS_FILE = "hosts.txt"
local HOSTS_FLAGS_FILE = "hosts_flags.txt" -- stores flags per host (serialized table)
local myIP

-- load IP
if not fs.exists(IP_FILE) then
    local f = fs.open(IP_FILE,"w")
    f.writeLine("")
    f.close()
    print(IP_FILE.." created. Use CLI command 'set ip <ip>' to assign IP before networking.")
    myIP = nil
else
    local f = fs.open(IP_FILE,"r")
    myIP = f.readLine()
    f.close()
    if myIP=="" then myIP=nil end
end

local function saveIP()
    local f = fs.open(IP_FILE,"w")
    f.writeLine(myIP)
    f.close()
end

-- in-memory hosts: name -> ip; flags: name -> {flags...}
local hosts = {}
local hostFlags = {}

-- load local hosts file if present
local function loadLocalHosts()
    hosts = {}
    hostFlags = {}
    if fs.exists(HOSTS_FILE) then
        local f = fs.open(HOSTS_FILE,"r")
        while true do
            local line = f.readLine()
            if not line then break end
            local key, ip = line:match("^(%S+)%s+(%S+)$")
            if key and ip then hosts[key] = ip end
        end
        f.close()
    end
    if fs.exists(HOSTS_FLAGS_FILE) then
        local f = fs.open(HOSTS_FLAGS_FILE,"r")
        local data = f.readAll()
        f.close()
        if data and data ~= "" then
            local ok, t = pcall(textutils.unserialize, data)
            if ok and type(t) == "table" then hostFlags = t end
        end
    end
end
loadLocalHosts()

local function saveLocalHosts()
    local f = fs.open(HOSTS_FILE,"w")
    for k,v in pairs(hosts) do f.writeLine(k.." "..v) end
    f.close()
    local f2 = fs.open(HOSTS_FLAGS_FILE,"w")
    f2.writeLine(textutils.serialize(hostFlags))
    f2.close()
end

-- ==========================
-- PACKET UTILITIES
-- ==========================
local seq = 0
local function makeUID()
    seq = seq + 1
    return tostring(os.time()).."-"..tostring(seq)
end

local function resolveAddress(input) -- input can be host keyword or raw ip
    return hosts[input] or input
end

local function sendPacket(dst, payload)
    if not myIP then
        print("Set your IP first with 'set ip <ip>' before sending packets.")
        return
    end
    local resolved = resolveAddress(dst)
    if not resolved then
        print("Unknown destination: "..tostring(dst))
        return
    end
    local packet = { uid = makeUID(), src = myIP, dst = resolved, ttl = 8, payload = payload }
    modem.transmit(1,1,packet)
end

-- ==========================
-- HOSTS UPDATE HANDLING
-- ==========================
-- apply diff: { added = {name={ip=...,flags={...}}}, removed = {"name"}, updated = {name={ip=...,flags={...}}} }
local function applyHostDiff(diff)
    local changed = false
    if diff.full and type(diff.hosts) == "table" then
        hosts = {}
        hostFlags = {}
        for name, info in pairs(diff.hosts) do
            hosts[name] = info.ip
            hostFlags[name] = info.flags or {}
        end
        changed = true
    else
        if type(diff.removed) == "table" then
            for _, name in ipairs(diff.removed) do
                if hosts[name] then hosts[name] = nil; hostFlags[name] = nil; changed = true end
            end
        end
        if type(diff.added) == "table" then
            for name, info in pairs(diff.added) do
                hosts[name] = info.ip
                hostFlags[name] = info.flags or {}
                changed = true
            end
        end
        if type(diff.updated) == "table" then
            for name, info in pairs(diff.updated) do
                hosts[name] = info.ip
                hostFlags[name] = info.flags or {}
                changed = true
            end
        end
    end
    if changed then saveLocalHosts(); print("Hosts list updated.") end
end

-- ==========================
-- FILE TRANSFER (request & receive)
-- ==========================
local receivingFile = false
local fileBuffer = {}
local expectedChunks = 0
local fileNameBeingReceived = ""

local function requestFile(serverKeyword, filename, password)
    local dst = resolveAddress(serverKeyword)
    if not dst then print("Unknown server keyword: "..serverKeyword) return end
    print("Requesting file '"..filename.."' from "..serverKeyword.." ("..dst..")")
    sendPacket(dst, { type="FILE_REQUEST", filename=filename, password=password })
end

-- ==========================
-- RECEIVE LOOP
-- ==========================
local function receiveLoop()
    while true do
        local e, side, ch, reply, message, dist = os.pullEvent("modem_message")
        if type(message) == "table" and myIP and (message.dst == myIP or message.dst == "0") then
            local payload = message.payload
            if type(payload) ~= "table" then
                print("Invalid payload from "..tostring(message.src))
            else
                if payload.type == "HELLO_REQUEST" then
                    -- reply with HELLO_REPLY (simple)
                    if myIP then sendPacket(message.src, { type = "HELLO_REPLY" }) end
                elseif payload.type == "FILE_CHUNK" then
                    if not receivingFile then
                        receivingFile = true
                        fileBuffer = {}
                        expectedChunks = payload.total or 1
                        fileNameBeingReceived = payload.filename or ("unknown_"..makeUID())
                        print("Receiving file "..fileNameBeingReceived.." ("..expectedChunks.." chunks)")
                    end
                    fileBuffer[payload.seq] = payload.data
                    if payload.seq % 5 == 0 or payload.seq == expectedChunks then
                        print("Received chunk "..payload.seq.."/"..expectedChunks)
                    end
                elseif payload.type == "FILE_END" then
                    if not receivingFile then
                        receivingFile = true
                        fileBuffer = {}
                        expectedChunks = 1
                        fileNameBeingReceived = payload.filename or ("unknown_"..makeUID())
                        print("Receiving file "..fileNameBeingReceived.." (1 chunk)")
                    end
                    local data = table.concat(fileBuffer)
                    local out = fs.open(fileNameBeingReceived, "w")
                    if out then out.write(data); out.close(); print("File '"..fileNameBeingReceived.."' saved successfully.")
                    else print("Failed to open file for writing: "..tostring(fileNameBeingReceived)) end
                    receivingFile = false
                    fileBuffer = {}
                    expectedChunks = 0
                    fileNameBeingReceived = ""
                elseif payload.type == "ERROR" then
                    print("Server error: "..(payload.message or "Unknown"))
                elseif payload.type == "PING" then
                    print("Received PING from "..message.src)
                    sendPacket(message.src, { type = "PING_REPLY", message = "pong" })
                elseif payload.type == "PING_REPLY" then
                    print("Reply from "..message.src..": "..(payload.message or "pong"))
                elseif payload.type == "UPDATE_HOSTS" or payload.type == "HOSTS_DIFF" then
                    -- router/hostServer updates hosts
                    if payload.type == "UPDATE_HOSTS" and type(payload.hosts) == "table" then
                        applyHostDiff({ full = true, hosts = payload.hosts })
                    elseif payload.type == "HOSTS_DIFF" and type(payload.diff) == "table" then
                        applyHostDiff(payload.diff)
                    elseif payload.request_full == true and type(payload.hosts) == "table" then
                        -- server may include full data in responses
                        applyHostDiff({ full = true, hosts = payload.hosts })
                    end
                else
                    -- generic message
                    print(("Message from %s: %s"):format(message.src, textutils.serialize(payload)))
                end
            end
        end
    end
end

-- ==========================
-- CLI & Commands
-- ==========================
local colorsList = { colors.cyan, colors.yellow, colors.green, colors.magenta }

local function printCommands()
    local cmds = {"set ip <ip>","ping <host>","getfile <server> <filename> <password>","list hosts","findhost <tag>","ip","run <program> [args]","exit"}
    print("Client ready. Commands:")
    for i, cmd in ipairs(cmds) do
        term.setTextColor(colorsList[(i-1)%#colorsList+1])
        print("  "..cmd)
    end
    term.setTextColor(colors.white)
end

local function findHostsByTag(tag)
    local results = {}
    for name, flags in pairs(hostFlags) do
        for _, f in ipairs(flags) do
            if f == tag then table.insert(results, {name = name, ip = hosts[name]}) end
        end
    end
    return results
end

local function cliLoop()
    printCommands()
    while true do
        io.write("> ")
        local line = io.read()
        if not line then break end
        local args = {}
        for word in line:gmatch("%S+") do table.insert(args,word) end
        local cmd = args[1]
        if cmd == "exit" then return
        elseif cmd == "set" and args[2] == "ip" and args[3] then
            myIP = args[3]; saveIP(); print("IP set to "..myIP)
        elseif cmd == "ping" and args[2] then
            sendPacket(args[2], { type = "PING" }); print("Ping sent to "..args[2])
        elseif cmd == "list" and args[2] == "hosts" then
            print("Known hosts:")
            for k,v in pairs(hosts) do print("  "..k.." -> "..v) end
        elseif cmd == "getfile" and args[2] and args[3] and args[4] then
            requestFile(args[2], args[3], args[4])
        elseif cmd == "findhost" and args[2] then
            local tag = args[2]
            local res = findHostsByTag(tag)
            if #res == 0 then print("No hosts with tag "..tag)
            else
                print("Hosts with tag "..tag..":")
                for _, r in ipairs(res) do print("  "..r.name.." -> "..r.ip) end
            end
        elseif cmd == "ip" then
            print("Current IP: "..tostring(myIP))
        elseif cmd == "run" and args[2] then
            local prog = args[2]; local progArgs = {}
            for i=3,#args do table.insert(progArgs,args[i]) end
            print("Launching program '"..prog.."' in background...")
            parallel.waitForAny(receiveLoop, cliLoop, function()
                local ok, err = pcall(function() shell.run(prog, table.unpack(progArgs)) end)
                if not ok then print("Error running "..prog..": "..tostring(err)) end
            end)
        else
            print("Commands: set ip <ip>, ping <host>, getfile <server> <filename> <password>, list hosts, findhost <tag>, ip, run <program> [args], exit")
        end
    end
end

-- ==========================
-- RUN CLIENT
-- ==========================
parallel.waitForAny(receiveLoop, cliLoop)
