#include <sourcemod>
#include <tf2_stocks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.0"

#define RED 0
#define BLU 1

public Plugin myinfo = 
{
	name = "Sniper block",
	author = "Zolak",
	description = "Blocks sniper class after certain conditions",
	version = PLUGIN_VERSION,
	url = "br.tf2pickup.org"
};

enum struct sniperInfo {
    char steamid[32];
    bool onSniper;
    int count;
    int time;
    float sniperStartTime;
    bool timeExceeded;
    TFClassType lastClass;
}

ConVar maxCvar;
ConVar timeCvar;
ArrayList sniperList;
bool gameStarted;
bool teamReadyState[2];



public void OnPluginStart()
{
	maxCvar = CreateConVar("sm_sniperblock_max", "5", "Max number of times a player can switch to sniper", FCVAR_PROTECTED);
	timeCvar = CreateConVar("sm_sniperblock_time", "300", "Max time in seconds a player can stay on sniper", FCVAR_PROTECTED);
}

public void OnMapStart()
{
	teamReadyState[RED] = false;
	teamReadyState[BLU] = false;
	gameStarted = false;
	sniperList = new ArrayList(sizeof(sniperInfo));
	HookEvent("player_changeclass", Event_ChangeClass, EventHookMode_Pre);
	HookEvent("player_spawn", Event_PlayerSpawn,EventHookMode_Post);
	HookEvent("tournament_stateupdate", Event_TournamentStateupdate);
	HookEvent("player_team", Event_PlayerTeam);
	HookEvent("tf_game_over", Event_GameOver);
	RegServerCmd("mp_tournament_restart", TournamentRestartHook);
}

int findSniperIndex(const char[] steamid) 
{
	sniperInfo sniper;
	for (int i = 0; i < sniperList.Length; i++) {
		sniperList.GetArray(i, sniper);
		if (StrEqual(sniper.steamid, steamid)) {
			return i;
		}
	}
	return -1;
}

bool changeSniperInfoOnSwitch(int client, char[] steamid, int sniperIndex, TFClassType lastClass) {
    sniperInfo sniper;
    int maxCount = GetConVarInt(maxCvar);
    int maxTime = GetConVarInt(timeCvar);
    
    if (sniperIndex != -1) {
        sniperList.GetArray(sniperIndex, sniper);

        if (sniper.time >= maxTime) {
            PrintToChat(client, "[SM] You have exceeded the allowed time for Sniper.");
            sniper.onSniper = false;
            sniper.timeExceeded = true;
            return false;
        }
        if (sniper.count < maxCount) {
            if (!sniper.onSniper) { //Only reset start time if not already sniper
                sniper.sniperStartTime = GetEngineTime();
            }
            sniper.onSniper = true;
            sniper.count += 1;
            sniperList.SetArray(sniperIndex, sniper);
            return true;
        }
        else {
            PrintToChat(client, "[SM] You have reached the maximum Sniper switches.");
            sniper.onSniper = false;
            return false;
        }
    }

    sniperInfo newSniper;
    strcopy(newSniper.steamid, sizeof(newSniper.steamid), steamid);
    newSniper.onSniper = true;
    newSniper.sniperStartTime = GetEngineTime();
    newSniper.count = 1;
    newSniper.time = 0;
    newSniper.timeExceeded = false;
    newSniper.lastClass = lastClass;
    
    sniperList.PushArray(newSniper);
    return true;
}

public Action Event_ChangeClass(Event event, const char[] name, bool dontBroadcast)
{
	if (gameStarted) { //Not in pregame
	    TFClassType classId = view_as<TFClassType>(event.GetInt("class"));
	    char steamid[64];
	    int userId = event.GetInt("userid");
	    int client = GetClientOfUserId(userId);
	    
	    GetClientAuthId(client, AuthId_Steam3, steamid, sizeof(steamid));
	    int sniperIndex = findSniperIndex(steamid);
	    
	    sniperInfo sniper;
	
	    if (sniperIndex != -1) {
	        sniperList.GetArray(sniperIndex, sniper);
	    }
	
	    if (classId == TFClass_Sniper) {
	        TFClassType lastClass = TF2_GetPlayerClass(client); //Last class before switching to sniper
	        if (!changeSniperInfoOnSwitch(client, steamid, sniperIndex, lastClass)) { //Cant switch to sniper
	            TF2_SetPlayerClass(client, sniper.lastClass, false);
	            return Plugin_Handled;
	        }
	    }
	    else if (sniperIndex != -1 && sniper.onSniper) {
	        //Player was sniper and is now changing class
	        float timeElapsed = GetEngineTime() - sniper.sniperStartTime;
	        sniper.time += RoundToFloor(timeElapsed);
	        
	        sniper.onSniper = false;
	        sniper.lastClass = classId;
	        
	        sniperList.SetArray(sniperIndex, sniper);
	    }
	}
	return Plugin_Continue;
}

public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	if (gameStarted) { //Not in pregame
	    TFClassType classId = view_as<TFClassType>(event.GetInt("class"));
	    char steamid[64];
	    int userId = event.GetInt("userid");
	    int client = GetClientOfUserId(userId);
	    
	    GetClientAuthId(client, AuthId_Steam3, steamid, sizeof(steamid));
	    int sniperIndex = findSniperIndex(steamid);
	    
	    if (sniperIndex != -1) {
	        sniperInfo sniper;
	        sniperList.GetArray(sniperIndex, sniper);
	
	        //Updating sniper playtime when spawning
	        if (classId == TFClass_Sniper) {
	            float timeElapsed = GetEngineTime() - sniper.sniperStartTime;
	            sniper.time += RoundToFloor(timeElapsed);
	            
	            //Check if time exceeded
	            if (sniper.time >= GetConVarInt(timeCvar) && !sniper.timeExceeded) {
	                sniper.timeExceeded = true;
	                sniper.onSniper = false;
	                PrintToChat(client, "[SM] You have exceeded the allowed time for Sniper.");
	                TF2_SetPlayerClass(client, sniper.lastClass, false);
	                TF2_RespawnPlayer(client);
	            }
	            sniperList.SetArray(sniperIndex, sniper);
	        }
	    }
	}
	return Plugin_Continue;
}

public void Event_TournamentStateupdate(Handle event, const char[] name, bool dontBroadcast)
{
    //More robust way of getting team ready status
    //The != 0 converts the result to a bool
    teamReadyState[0] = GameRules_GetProp("m_bTeamReady", 1, 2) != 0; //Red team
    teamReadyState[1] = GameRules_GetProp("m_bTeamReady", 1, 3) != 0; //Blue team

    //If both teams are ready, game is starting
    if (teamReadyState[RED] && teamReadyState[BLU])
    {
        gameStarted = true;
    }
    else
    {
		gameStarted = false;
    }
}

public Action Event_PlayerTeam(Handle event, const char[] name, bool dontBroadcast)
{
    //Players switching teams unreadies teams without triggering tournament_stateupdate.
    teamReadyState[RED] = GameRules_GetProp("m_bTeamReady", 1, 2) != 0;
    teamReadyState[BLU] = GameRules_GetProp("m_bTeamReady", 1, 3) != 0;
    return Plugin_Continue;
}

public Action Event_GameOver(Handle event, const char[] name, bool dontBroadcast)
{
	teamReadyState[RED] = false;
	teamReadyState[BLU] = false;
	gameStarted = false;
	sniperList = new ArrayList(sizeof(sniperInfo));
	if (sniperList == null)
	{
		delete sniperList; 
	}
	sniperList = new ArrayList(sizeof(sniperInfo));
	return Plugin_Continue;
}

public Action TournamentRestartHook(int args)
{
	teamReadyState[RED] = false;
	teamReadyState[BLU] = false;
	gameStarted = false;
	if (sniperList != null)
	{
		delete sniperList; 
	}
	sniperList = new ArrayList(sizeof(sniperInfo));
	return Plugin_Continue;
}