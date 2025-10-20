--TO INSTALL RUN "pastebin get cYVhLAtp updater.lua" ON SHELL
local run = true

local function routerUpdater()
    if fs.exists("router.lua") then
        fs.delete("router.lua")
        print("Deleted old router.lua)
    else
        print("router.lua not found. Installing router.lua)
    end

    shell.run("pastebin get jR4Aibrh router.lua")
    print("Downloaded latest router.lua)
				term.setTextColor(colors.yellow)
    print("Routers can also be run with servers installed. Please update any server files on device.")
				term.setTextColor(colors.white)

    run = false
end

local function clientUpdater()
	if fs.exists("client.lua") then
    	fs.delete("client.lua")
    	print("Deleted old client.lua")
	else
	    print("client.lua not found installing client.lua")
	end
	shell.run("pastebin get U9VVPEzW client.lua")
	print("Downloaded latest client.lua")
    run = false
end

local function switchUpdater()
	if fs.exists("switch.lua") then
    	fs.delete("switch.lua")
    	print("Deleted old switch.lua")
	else
	    print("switch.lua not found installing switch.lua")
	end
	shell.run("pastebin get ajwx98XZ switch.lua")
	print("Downloaded latest switch.lua")
    run = false
end

local function fileServerUpdater()
	if fs.exists("fileServer.lua") then
    	fs.delete("fileServer.lua")
    	print("Deleted old fileServer.lua")
	else
	    print("fileServer.lua not found installing fileServer.lua")
	end
	shell.run("pastebin get Ld5d5M5M fileServer.lua")
	print("Downloaded latest fileServer.lua")
    run = false
end

local function hostServerUpdater()
	if fs.exists("hostServer.lua") then
    	fs.delete("hostServer.lua")
    	print("Deleted old hostServer.lua")
	else
	    print("hostServer.lua not found installing hostServer.lua")
	end
	shell.run("pastebin get sy6pUE0Z hostServer.lua")
	print("Downloaded latest hostServer.lua")
    run = false
 end

local function Updater()
    if fs.exists("updater.lua") then
        fs.delete("updater.lua")
        print("Deleted old updater.lua")
    else
        print("updater.lua not found installing updater.lua")
    end
    shell.run("pastebin get cYVhLAtp updater.lua")
    print("Downloaded latest updater.lua")
    run = false
end

local function cliLoop()
    term.setTextColor(colors.red)
    print("UPDATER MUST BE RAN IN SAME DIR AS FILE YOU WANT TO UPDATE")
    term.setTextColor(colors.white)
    print("Updater ready. Command arguments:")
    print("update <router,client,switch,fileServer,hostServer>")
    while run do
       	term.setTextColor(colors.yellow)
        io.write("> ")
        term.setTextColor(colors.white)
        local line = io.read()
        if not line then break end
        local args = {}
        for word in line:gmatch("%S+") do table.insert(args, word) end
        local cmd = args[1]
        if cmd=="update" then
            		local arg1 = args[2]
                    if arg1=="router" then
                		routerUpdater()
                    elseif arg1=="client" then
                		clientUpdater()
                	elseif arg1=="switch" then
                		switchUpdater()
                	elseif arg1=="fileServer" then
                		fileServerUpdater()
                	elseif arg1=="hostServer" then
                		hostServerUpdater()
                	elseif arg1=="updater" then
                        Updater()
                    else
                		print("Usage: update router | update client | update switch | update fileServer | update hostServer") 
            		end
        else
        	print("NO OTHER COMMANDS AVAILBLE MUST BE: update <file>")
        end
    end
end

cliLoop()
