-- client.lua Version 1.4
-- Compatible with HostServer 1.72+ diff update system
-- CC:Tweaked wired client for IP router & server systems
-- Supports hostname keywords, HELLO_REPLY only, secure plaintext file transfer, standardized IP file
-- Added automatic multishell self-launch and host sync updates

-- ==========================
-- SELF-LAUNCH IN MULTISHELL
-- ==========================
if type(multishell) == "table" and type(multishell.getCurrent) == "function" then
    local currentProgram = shell.getRunningProgram()
    if multishell.getCurrent() == 1 then
        multishell.launch(shell, currentProgram)
        return
    end
end

-- ==========================
-- DEBUG MODE
-- ==========================
local DEBUG = false
local function debugPrint(msg)
    if DEBUG then print("[DEBUG] " .. msg) end
end

-- ==========================
-- NETWORK CONFIG
-- ==========================
local modemSide = "back"
local modem = peripheral.wrap(modemSide)
modem.open(1)

local IP_FILE = "ip.txt"
local HOSTS_FILE = "hosts.txt"
local SERVER_FILE = "host_server_ip.txt"

local myIP
local hosts = {}
local hostServerIP

-- ==========================
-- IP MANAGEMENT
-- ==========================
if not fs.exists(IP_FILE) then
    local f = fs.open(IP_FILE,"w") f.writeLine("") f.close()
    term.setTextColor(colors.yellow)
    print(IP_FILE.." created. Use CLI command 'set ip <ip>' to assign IP before networking.")
    term.setTextColor(colors.white)
else
    local f = fs.open(IP_FILE,"r")
    myIP = f.readLine()
    f.close()
    if myIP == "" then myIP = nil end
end

local function saveIP()
    local f = fs.open(IP_FILE,"w")
    f.writeLine(myIP or "")
    f.close()
end

-- ==========================
-- HOSTS MANAGEMENT
-- ==========================
local function loadHosts()
    if fs.exists(HOSTS_FILE) then
        local f = fs.open(HOSTS_FILE, "r")
        local data = f.readAll()
        f.close()
        if data and data ~= "" then
            local ok, t = pcall(textutils.unserialize, data)
            if ok and type(t) == "table" then
                hosts = t
                debugPrint("Loaded " .. tostring(#(hosts or {})) .. " hosts.")
                return
            end
        end
    end
    hosts = {}
end

local function saveHosts()
    local f = fs.open(HOSTS_FILE, "w")
    f.writeLine(textutils.serialize(hosts))
    f.close()
end

-- Initialize hosts.txt if missing
if not fs.exists(HOSTS_FILE) then
    local f = fs.open(HOSTS_FILE, "w")
    f.writeLine(textutils.serialize({}))
    f.close()
    term.setTextColor(colors.yellow)
    print("hosts.txt created. Awaiting synchronization from host server.")
    term.setTextColor(colors.white)
end
loadHosts()

-- ==========================
-- HOST SERVER DISCOVERY
-- ==========================
local function saveServerIP()
    local f = fs.open(SERVER_FILE, "w")
    f.writeLine(hostServerIP or "")
    f.close()
end

local function loadServerIP()
    if fs.exists(SERVER_FILE) then
        local f = fs.open(SERVER_FILE, "r")
        hostServerIP = f.readLine()
        f.close()
    end
end
loadServerIP()

-- ==========================
-- PACKET UTILITIES
-- ==========================
local seq = 0
local function makeUID()
    seq = seq + 1
    return tostring(os.time()).."-"..tostring(seq)
end

local function resolveAddress(input)
    if hosts[input] and hosts[input].ip then return hosts[input].ip end
    return input
end

local function sendPacket(dst, payload)
    if not myIP then
        term.setTextColor(colors.yellow)
        print("Set your IP first with 'set ip <ip>' before sending packets.")
        term.setTextColor(colors.white)
        return
    end
    local resolved = resolveAddress(dst)
    if not resolved then
        term.setTextColor(colors.red)
        print("Unknown destination: "..tostring(dst))
        term.setTextColor(colors.white)
        return
    end
    local packet = { uid=makeUID(), src=myIP, dst=resolved, ttl=8, payload=payload }
    modem.transmit(1,1,packet)
end

local function broadcast(payload)
    local packet = { uid=makeUID(), src=myIP or "unknown", dst="0", ttl=8, payload=payload }
    modem.transmit(1,1,packet)
end

-- ==========================
-- HELLO REPLY
-- ==========================
local function replyHello(requester)
    if not myIP then return end
    sendPacket(requester, { type="HELLO_REPLY" })
    debugPrint("Replied to HELLO_REQUEST from "..requester)
end

-- ==========================
-- FILE TRANSFER (unchanged)
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
-- HOST UPDATE HANDLING
-- ==========================
local function handleUpdateHosts(payload)
    if type(payload.hosts) == "table" then
        hosts = payload.hosts
        saveHosts()
        debugPrint("[HostSync] Full hosts list updated.")
    end
end

local function handleHostsDiff(payload)
    local diff = payload.diff
    if not diff then return end

    for _, name in ipairs(diff.removed or {}) do hosts[name] = nil end
    for name, info in pairs(diff.added or {}) do hosts[name] = info end
    for name, info in pairs(diff.updated or {}) do hosts[name] = info end
    saveHosts()
    debugPrint("[HostSync] Hosts diff applied.")
end

local function discoverHostServer()
    debugPrint("[HostSync] Discovering host server...")
    broadcast({ type="DISCOVER_HOST_SERVER" })
end

local function requestFullHosts()
    if hostServerIP then
        debugPrint("[HostSync] Requesting full host table from " .. hostServerIP)
        sendPacket(hostServerIP, { type="REQUEST_HOSTS" })
    else
        discoverHostServer()
    end
end

-- ==========================
-- RECEIVE LOOP
-- ==========================
local function receiveLoop()
    while true do
        local _, _, _, _, message = os.pullEvent("modem_message")
        if type(message) == "table" and type(message.payload) == "table" then
            local payload = message.payload

            if payload.type == "HELLO_REQUEST" then
                replyHello(message.src)
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
                local data = table.concat(fileBuffer)
                local out = fs.open(fileNameBeingReceived, "w")
                if out then
                    out.write(data) out.close()
                    print("File '"..fileNameBeingReceived.."' saved successfully.")
                else
                    term.setTextColor(colors.red)
                    print("Failed to write file: "..fileNameBeingReceived)
                    term.setTextColor(colors.white)
                end
                receivingFile, fileBuffer, expectedChunks, fileNameBeingReceived = false, {}, 0, ""
            elseif payload.type == "ERROR" then
                term.setTextColor(colors.red)
                print("Server error: "..(payload.message or "Unknown"))
                term.setTextColor(colors.white)
            elseif payload.type == "PING" then
                sendPacket(message.src,{ type="PING_REPLY", message="pong" })
            elseif payload.type == "PING_REPLY" then
                print("Reply from "..message.src..": "..(payload.message or "pong"))
            elseif payload.type == "UPDATE_HOSTS" then
                handleUpdateHosts(payload)
            elseif payload.type == "HOSTS_DIFF" then
                handleHostsDiff(payload)
            elseif payload.type == "HOST_SERVER_HERE" then
                if payload.server_ip then
                    hostServerIP = payload.server_ip
                    saveServerIP()
                    debugPrint("[HostSync] Host server discovered at " .. hostServerIP)
                    requestFullHosts()
                end
            else
                debugPrint("Unhandled packet: "..textutils.serialize(payload))
            end
        end
    end
end

-- ==========================
-- CLI LOOP
-- ==========================
local colorsList = { colors.cyan, colors.yellow, colors.green, colors.magenta }

local function printCommands()
    local cmds = {
        "set ip <ip>",
        "ping <host>",
        "getfile <server> <filename> <password>",
        "list hosts",
        "sync hosts",
        "ip",
        "run <program> [args]",
        "exit"
    }
    print("Client ready. Commands:")
    for i, cmd in ipairs(cmds) do
        term.setTextColor(colorsList[(i-1)%#colorsList+1])
        print("  "..cmd)
    end
    term.setTextColor(colors.white)
end

local function cliLoop()
    printCommands()
    while true do
        io.write("> ")
        local line = io.read()
        if not line then break end
        local args = {}
        for word in line:gmatch("%S+") do table.insert(args, word) end
        local cmd = args[1]
        if cmd == "exit" then return
        elseif cmd == "set" and args[2] == "ip" and args[3] then
            myIP = args[3]; saveIP(); print("IP set to "..myIP)
        elseif cmd == "ping" and args[2] then
            sendPacket(args[2], { type="PING" }); print("Ping sent to "..args[2])
        elseif cmd == "list" and args[2] == "hosts" then
            print("Known hosts:")
            for k,v in pairs(hosts) do
                print(("  %-10s -> %s"):format(k, v.ip or "??"))
            end
        elseif cmd == "sync" and args[2] == "hosts" then
            requestFullHosts()
        elseif cmd == "getfile" and args[2] and args[3] and args[4] then
            requestFile(args[2], args[3], args[4])
        elseif cmd == "ip" then
            print("Current IP: "..tostring(myIP))
        elseif cmd == "run" and args[2] then
            local prog=args[2]; local progArgs={}
            for i=3,#args do table.insert(progArgs,args[i]) end
            print("Launching program '"..prog.."' in background...")
            parallel.waitForAny(receiveLoop, cliLoop, function()
                local ok, err = pcall(function() shell.run(prog, table.unpack(progArgs)) end)
                if not ok then print("Error running "..prog..": "..tostring(err)) end
            end)
        else
            term.setTextColor(colors.red)
            print("Error: Unrecognized command")
            term.setTextColor(colors.white)
            printCommands()
        end
    end
end

-- ==========================
-- STARTUP
-- ==========================
if not hostServerIP then discoverHostServer() else requestFullHosts() end
parallel.waitForAny(receiveLoop, cliLoop)
