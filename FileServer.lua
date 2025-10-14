-- fileServer.lua
-- CC:Tweaked server for file sharing with password protection
-- Features:
--   - Automatic IP from server_ip.txt
--   - HELLO packet to router
--   - Keyword/IP mapping from hosts.txt
--   - Responds to file requests only if password is correct
--   - Message sending/receiving
--   - Ping reply support

local modemSide = "back"
local modem = peripheral.wrap(modemSide)
modem.open(1)

-- ==========================
-- CONFIGURATION
-- ==========================
local PASSWORD_FILE = "server_password.txt"
local CHUNK_SIZE = 512

-- ==========================
-- LOAD SERVER IP
-- ==========================
local ipFile = "server_ip.txt"
if not fs.exists(ipFile) then
    error("server_ip.txt not found! Create a file with the server's IP.")
end
local file = fs.open(ipFile, "r")
local myIP = file.readLine()
file.close()
if not myIP or myIP:match("^%d+%.%d+%.%d+%.%d+$") == nil then
    error("server_ip.txt must contain a valid IPv4 address like 192.168.0.20")
end
print("Server IP: "..myIP)

-- ==========================
-- LOAD PASSWORD
-- ==========================
if not fs.exists(PASSWORD_FILE) then
    error("server_password.txt not found! Create a file with the server password.")
end
local file = fs.open(PASSWORD_FILE, "r")
local SERVER_PASSWORD = file.readLine()
file.close()
if not SERVER_PASSWORD or #SERVER_PASSWORD == 0 then
    error("Server password cannot be empty!")
end

-- ==========================
-- LOAD HOSTS KEYWORDS
-- ==========================
local hosts = {}
if fs.exists("hosts.txt") then
    local file = fs.open("hosts.txt","r")
    while true do
        local line = file.readLine()
        if not line then break end
        local key, ip = line:match("^(%S+)%s+(%S+)$")
        if key and ip then hosts[key] = ip end
    end
    file.close()
end

-- ==========================
-- PACKET UTILITIES
-- ==========================
local seq = 0
local function makeUID()
    seq = seq + 1
    return tostring(os.time()).."-"..tostring(seq)
end

local function sendPacket(dst, payload)
    local packet = { uid=makeUID(), src=myIP, dst=dst, ttl=8, payload=payload }
    modem.transmit(1,1,packet)
end

-- ==========================
-- HELLO PACKET
-- ==========================
local myKeyword
for k,v in pairs(hosts) do
    if v == myIP then myKeyword = k break end
end
sendPacket("0", { type="HELLO_CLIENT", keyword=myKeyword })

-- ==========================
-- FILE TRANSFER FUNCTIONS
-- ==========================
local function sendFile(dst, filename)
    if not fs.exists(filename) then
        print("File does not exist: "..filename)
        return
    end

    local file = fs.open(filename,"r")
    local data = file.readAll()
    file.close()

    local chunks = {}
    for i=1,#data,CHUNK_SIZE do
        local chunk = data:sub(i, math.min(i+CHUNK_SIZE-1, #data))
        table.insert(chunks, chunk)
    end

    print("Sending file "..filename.." to "..dst.." in "..#chunks.." chunks")
    for i,chunk in ipairs(chunks) do
        sendPacket(dst, { type="FILE_CHUNK", filename=filename, seq=i, total=#chunks, data=chunk })
    end
    sendPacket(dst, { type="FILE_END", filename=filename })
    print("File "..filename.." sent successfully")
end

-- ==========================
-- RECEIVE LOOP
-- ==========================
local function receiveLoop()
    while true do
        local e, side, ch, reply, message, dist = os.pullEvent("modem_message")
        if type(message)=="table" and message.dst==myIP then
            local payload = message.payload
            if type(payload) ~= "table" then
                print("Invalid payload from "..tostring(message.src))
            else
                if payload.type == "FILE_REQUEST" then
                    if payload.password == SERVER_PASSWORD then
                        print("Received file request from "..message.src.." for "..payload.filename)
                        sendFile(message.src, payload.filename)
                    else
                        print("Invalid password from "..message.src.." for file "..payload.filename)
                        sendPacket(message.src, { type="ERROR", message="Invalid password" })
                    end
                elseif payload.type == "PING" then
                    print("Received PING from " .. message.src)
                    sendPacket(message.src, { type="PING_REPLY", message="pong" })
                else
                    print(("Message from %s: %s"):format(message.src, textutils.serialize(payload)))
                end
            end
        end
    end
end

-- ==========================
-- CLI LOOP
-- ==========================
local function cliLoop()
    print("Server ready. Commands: ip, list hosts, exit")
    while true do
        io.write("> ")
        local line = io.read()
        if not line then break end
        if line=="exit" then return end
        if line=="ip" then
            print("Server IP:", myIP)
        elseif line=="list hosts" then
            print("Known hosts:")
            for k,v in pairs(hosts) do
                print("  "..k.." -> "..v)
            end
        else
            print("Commands: ip, list hosts, exit")
        end
    end
end

-- ==========================
-- START SERVER
-- ==========================
parallel.waitForAny(receiveLoop, cliLoop)
