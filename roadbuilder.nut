/*
 * This file is part of CityLifeAI, an AI for OpenTTD.
 *
 * It's free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the
 * Free Software Foundation, version 2 of the License.
 *
 */

enum PathfinderStatus {
    IDLE,
    RUNNING,
    FINISHED
};

class RoadBuilder
{
    status = null;
    pathfinder = null;
    town_a = null;
    town_b = null;
    road_type = null;
    path = null;

    constructor()
    {
        this.pathfinder =  RoadPathFinder();
        this.status = PathfinderStatus.IDLE;
    }
}

function RoadBuilder::Init(towns)
{
    if (this.status != PathfinderStatus.IDLE)
        return false;

    if (!this.FindTownsToConnect(towns))
        return false;
    
    this.road_type =this.FindFastestRoadType();

    this.pathfinder.InitializePath([AITown.GetLocation(this.town_a)], [AITown.GetLocation(this.town_b)], true);
    this.pathfinder.SetMaxIterations(500000);
    this.pathfinder.SetStepSize(100);
    this.status = PathfinderStatus.RUNNING;

    return true;
}

function RoadBuilder::FindFastestRoadType()
{
    local road_types = AIRoadTypeList(AIRoad.ROADTRAMTYPES_ROAD);
    road_types.Valuate(AIRoad.GetMaxSpeed);
    road_types.Sort(AIList.SORT_BY_VALUE, false);
    return road_types.Begin();
}

function RoadBuilder::FindTownsToConnect(towns)
{
    local town_list = AITownList();
    town_list.Valuate(AITown.GetPopulation);
    town_list.Sort(AIList.SORT_BY_VALUE, false);

    this.town_a = null;
    foreach (town_id, population in town_list)
    {
        if (towns[town_id].connections.len() < 5 && population / 2000 > towns[town_id].connections.len())
        {
            this.town_a = town_id;
            town_list.RemoveItem(town_id);
            break;
        }
    }

    if (this.town_a == null)
        return false;

    town_list.Valuate(AITown.GetDistanceManhattanToTile, AITown.GetLocation(this.town_a));
    town_list.Sort(AIList.SORT_BY_VALUE, true);

    this.town_b = null;
    foreach (town_id, distance in town_list)
    {
        if (distance < 100 && towns[town_id].connections.len() <= towns[this.town_a].connections.len())
        {
            local connection_exists = false;
            foreach (connection in towns[this.town_a].connections)
            {
                if (connection == town_id)
                {
                    connection_exists = true;
                    break;
                }
            }

            if (!connection_exists)
            {
                this.town_b = town_id;
                break;
            }
        }
    }

    if (this.town_b == null) {
        towns[this.town_a].connections.append(-1); // No available town to connect to, increase the connections
        return false;
    }

    return true;
}

function RoadBuilder::FindPath(towns)
{
    if (this.status != PathfinderStatus.RUNNING)
        return false;

    AIRoad.SetCurrentRoadType(this.road_type);

    this.path = this.pathfinder.FindPath();
    if (this.path == null)
    {
        local pf_err = this.pathfinder.GetFindPathError();
        if (pf_err != RoadPathFinder.PATH_FIND_NO_ERROR)
        {
            AILog.Info("Path between " + AITown.GetName(this.town_a) + " and " + AITown.GetName(this.town_b) + " failed " + pf_err);
            towns[this.town_a].connections.append(this.town_b);
            towns[this.town_b].connections.append(this.town_a);
            this.status = PathfinderStatus.IDLE;
        }
        return false;
    }

    return true;
}

function RoadBuilder::BuildRoad(towns)
{
    AILog.Info("Building road between " + AITown.GetName(this.town_a) + " and " + AITown.GetName(this.town_b));
    while (this.path != null) {
		local par = this.path.GetParent();

		if (par != null) {
			local last_node = this.path.GetTile();

			if (AIMap.DistanceManhattan(this.path.GetTile(), par.GetTile()) == 1 ) 
            {
				if (AIRoad.AreRoadTilesConnected(this.path.GetTile(), par.GetTile())) 
                {
					if (AITile.HasTransportType(par.GetTile(), AITile.TRANSPORT_RAIL))
					{
						local bridge_result = SuperLib.Road.ConvertRailCrossingToBridge(par.GetTile(), this.path.GetTile());
						if (bridge_result.succeeded == true)
						{
							local new_par = par;
							while (new_par != null && new_par.GetTile() != bridge_result.bridge_start && new_par.GetTile() != bridge_result.bridge_end)
							{
								new_par = new_par.GetParent();
							}
							
							par = new_par;
						}
						else
						{
							AILog.Info("Failed to bridge railway crossing");
						}
					}

				} else {

					/* Look for longest straight road and build it as one build command */
					local straight_begin = this.path;
					local straight_end = par;

                    local prev = straight_end.GetParent();
                    while(prev != null && 
                            SuperLib.Tile.IsStraight(straight_begin.GetTile(), prev.GetTile()) &&
                            AIMap.DistanceManhattan(straight_end.GetTile(), prev.GetTile()) == 1)
                    {
                        straight_end = prev;
                        prev = straight_end.GetParent();
                    }

                    /* update the looping vars. (this.path is set to par in the end of the main loop) */
                    par = straight_end;

					// Build road
                    local result = false;
                    while (!result)
                    {
                        result = AIRoad.BuildRoad(straight_begin.GetTile(), straight_end.GetTile());
                        if (AIError.GetLastError() != AIError.ERR_VEHICLE_IN_THE_WAY)
                            break;
                    }

                    if (!result && !AIError.GetLastError() == AIError.ERR_ALREADY_BUILT)
                        AILog.Info("Build road error: " + AIError.GetLastErrorString());
				}
			} else {
				if (AIBridge.IsBridgeTile(this.path.GetTile())) {
					/* A bridge exists */

					// Check if it is a bridge with low speed
					local bridge_type_id = AIBridge.GetBridgeID(this.path.GetTile())
					local bridge_max_speed = AIBridge.GetMaxSpeed(bridge_type_id);

					if(bridge_max_speed < 100) // low speed bridge
					{
						local other_end_tile = AIBridge.GetOtherBridgeEnd(this.path.GetTile());
						local bridge_length = AIMap.DistanceManhattan( this.path.GetTile(), other_end_tile ) + 1;
						local bridge_list = AIBridgeList_Length(bridge_length);

						bridge_list.Valuate(AIBridge.GetMaxSpeed);
						bridge_list.KeepAboveValue(bridge_max_speed);

						if(!bridge_list.IsEmpty())
						{
							// Pick a random faster bridge than the current one
							bridge_list.Valuate(AIBase.RandItem);
							bridge_list.Sort(AIList.SORT_BY_VALUE, AIList.SORT_ASCENDING);

							// Upgrade the bridge
                            local result = false;
                            while (!result)
                            {
                                result = AIBridge.BuildBridge( AIVehicle.VT_ROAD, bridge_list.Begin(), this.path.GetTile(), other_end_tile );
                                if (AIError.GetLastError() != AIError.ERR_VEHICLE_IN_THE_WAY)
                                    break;
                            }

                            if (!result && !AIError.GetLastError() == AIError.ERR_ALREADY_BUILT)
							    AILog.Info("Upgrade bridge error: " + AIError.GetLastErrorString());
						}
					}

				} else if(AITunnel.IsTunnelTile(this.path.GetTile())) {
					/* A tunnel exists */
					
					// All tunnels have equal speed so nothing to do
				} else {
					/* Build a bridge or tunnel. */

					/* If it was a road tile, demolish it first. Do this to work around expended roadbits. */
					if (AIRoad.IsRoadTile(this.path.GetTile()) && 
							!AIRoad.IsRoadStationTile(this.path.GetTile()) &&
							!AIRoad.IsRoadDepotTile(this.path.GetTile())) {
						AITile.DemolishTile(this.path.GetTile());
					}
					if (AITunnel.GetOtherTunnelEnd(this.path.GetTile()) == par.GetTile()) {

						local result = AITunnel.BuildTunnel(AIVehicle.VT_ROAD, this.path.GetTile());
						if (!result && !AIError.GetLastError() == AIError.ERR_ALREADY_BUILT) {
                            AILog.Info("Upgrade tunnel error: " + AIError.GetLastErrorString());
						}
					} else {
						local bridge_list = AIBridgeList_Length(AIMap.DistanceManhattan(this.path.GetTile(), par.GetTile()) +1);
						bridge_list.Valuate(AIBridge.GetMaxSpeed);

                        local result = false;
                        while (!result)
                        {
                            result = AIBridge.BuildBridge(AIVehicle.VT_ROAD, bridge_list.Begin(), this.path.GetTile(), par.GetTile());
                            if (AIError.GetLastError() != AIError.ERR_VEHICLE_IN_THE_WAY)
                                break;
                        }

                        if (!result && !AIError.GetLastError() == AIError.ERR_ALREADY_BUILT)
                            AILog.Info("Upgrade bridge error: " + AIError.GetLastErrorString());
					}
				}
			}
		}
		this.path = par;
	}

    this.status = PathfinderStatus.IDLE;
    AILog.Info("Path between " + AITown.GetName(this.town_a) + " and " + AITown.GetName(this.town_b) + " built");
    towns[this.town_a].connections.append(this.town_b);
    towns[this.town_b].connections.append(this.town_a);
}