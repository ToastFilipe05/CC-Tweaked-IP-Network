local function routerUpdater()
    if fs.exists("router.lua")then
        fs.delete("router.lua")
        print("Deleted old router.lua")
    else
        print("router.lua not found. Installing router.lua")
    end

    shell.run("pastebin get jR4Aibrh router.lua")
    print("Downloaded latest router.lua")
    print("Routers can also be run with servers installed. Please update any server files on device.")
end

local function cellTowerUpdater()
    if fs.exists("cellTower.lua") then
        fs.delete("cellTower.lua")
        print("Deleted old celTower.lua")
    else
        print("cellTower.lua not found installing cellTower.lua")
    end
    shell.run("pastebin get Ys872m66 cellTower.lua")
    print("Downloaded latest cellTower.lua")
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
end

local function wirelessClientUpdater()
	if fs.exists("wirelessClient.lua") then
    	fs.delete("wirelessClient.lua")
    	print("Deleted old wirelessClient.lua")
	else
	    print("wirelessClient.lua not found installing wirelessClient.lua")
	end
	shell.run("pastebin get QQAqGvFw wirelessClient.lua")
	print("Downloaded latest wirelessClient.lua")
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
end

local function cliLoop()
    term.setTextColor(colors.red)
    print("UPDATER MUST BE RAN IN SAME DIR AS FILE YOU WANT TO UPDATE")
    term.setTextColor(colors.white)
    print("Updater ready. Command arguments:")
    print("update <router,client,switch,fileServer,hostServer,updater,cellTower,wirelessClient>")
    while true do
       	term.setTextColor(colors.yellow)
        io.write("> ")
        term.setTextColor(colors.white)
        local line = io.read()
        if not line then break end
        local args = {}
        for word in line:gmatch("%S+") do table.insert(args, word) end
        local cmd = args[1]
        if cmd=="router" then
       		routerUpdater()
			break
        elseif cmd=="client" then
       		clientUpdater()
			break
		elseif cmd=="wirelessClient" then
        	wirelessClientUpdater()
			break
        elseif cmd=="switch" then
            switchUpdater()
			break
        elseif cmd=="fileServer" then
            fileServerUpdater()
			break
        elseif cmd=="hostServer" then
            hostServerUpdater()
			break
		elseif cmd=="cellTower" then
            cellTowerUpdater()
			break
        elseif cmd=="updater" then
            Updater()
			break
        elseif cmd=="quit" then
            break
        else
           	print("Usage: router | client | switch | fileServer | hostServer | updater | cellTower | wirelessClient | quit") 
        end
    end
end

cliLoop()
