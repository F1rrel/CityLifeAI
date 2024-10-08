/*
 * This file is part of CityLifeAI, an AI for OpenTTD.
 *
 * It's free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the
 * Free Software Foundation, version 2 of the License.
 *
 */

require("version.nut");
require("vehicle.nut");
require("town.nut");
require("roadbuilder.nut");

// Import ToyLib
import("Library.AIToyLib", "AIToyLib", 2);
import("Library.SCPLib", "SCPLib", 45);
import("util.superlib", "SuperLib", 40);

RoadPathFinder <- SuperLib.RoadPathFinder;

class CityLife extends AIController
{
    load_saved_data = null;
    current_save_version = null;
    ai_init_done = null;
    duplicit_ai = null;
    current_date = null;
	current_month = null;
	current_year = null;
    toy_lib = null;
    towns = null;
    road_builder = null;

    constructor()
    {
        this.load_saved_data = false;
        this.current_save_version = SELF_MAJORVERSION;    // Ensures compatibility between revisions
        this.ai_init_done = false;
        this.duplicit_ai = false;
        this.current_date = 0;
        this.current_month = 0;
        this.current_year = 0;
        this.road_builder = RoadBuilder();
        ::TownDataTable <- {};
    } // constructor
}

function CityLife::Init()
{
    // Wait for game to start and give time to SCP
    this.Sleep(74);

    // Version
    AILog.Info("Version: " + SELF_MAJORVERSION + "." + SELF_MINORVERSION )

    // Init ToyLib
    this.toy_lib = AIToyLib(null);

    // Init time
    local date = AIDate.GetCurrentDate();
    this.current_date = date;
    this.current_month = AIDate.GetMonth(date);
    this.current_year = AIDate.GetYear(date);

    if (!this.load_saved_data)
    {
        // Set company name
        if (!AICompany.SetName("CityLifeAI"))
        {
            this.duplicit_ai = true;
            local i = 2;
            while (!AICompany.SetName("CityLifeAI #" + i))
            {
                i += 1;
                if (i > 255) break;
            }
        }

        // Enable automatic renewal of vehicles
        AICompany.SetAutoRenewStatus(true);
        AICompany.SetAutoRenewMonths(1);
    }

    // Create Vehicles list
    RefreshEngineList();

    // Create the towns list
	AILog.Info("Create town list ... (can take a while on large maps)");
	this.towns = this.CreateTownList();

    // Ending initialization
	this.ai_init_done = true;

    // Now we can free ::TownDataTable
	::TownDataTable = null;
}

function CityLife::Start()
{
    this.Init();

    // Main loop
    local town_index = 0;
	while (true)
    {
        // Get ticks
        local start_tick = AIController.GetTick();

        // Run the daily functions
        local date = AIDate.GetCurrentDate();
        if (date - this.current_date != 0)
        {
            this.current_date = date;

            this.HandleEvents();
            AIToyLib.Check();
        }

        // Run the monthly functions
        local month = AIDate.GetMonth(date);
        if (month - this.current_month != 0)
        {
            AILog.Info("Monthly update");

            this.MonthlyManageTowns();
            // this.MonthlyManageRoadBuilder();
            this.AskForMoney();

            this.current_month = month;
        }

        // Run the yearly functions
        local year = AIDate.GetYear(date);
        if (year - this.current_year != 0)
        {
            AILog.Info("Yearly Update");

            RefreshEngineList();

            this.current_year = year
        }

        // Manage town and road builder only when there is enough money
        local bank_balance = AICompany.GetBankBalance(AICompany.COMPANY_SELF);
        if (bank_balance > 50000)
        {
            this.ManageTown(this.towns[town_index++]);
            town_index = town_index >= this.towns.len() ? 0 : town_index;
        }
        // if (bank_balance >= 250000)
        //     this.ManageRoadBuilder();

        // Prevent excesive cpu usage
        if (AIController.GetTick() - start_tick < 5)
            AIController.Sleep(5);
    }
}

function CityLife::HandleEvents()
{
    while (AIEventController.IsEventWaiting())
    {
		local event = AIEventController.GetNextEvent();
		switch (event.GetEventType())
        {
		    // On town founding, add a new town to the list
            case AIEvent.ET_TOWN_FOUNDED:
                event = AIEventTownFounded.Convert(event);
                local town_id = event.GetTownID();
                // AILog.Info("New town founded: " + AITown.GetName(town_id));
                if (AITown.IsValidTown(town_id))
                    this.towns[town_id] <- Town(town_id, false);
                break;

            // Lost vehicles are sent to the nearest depot (for parade)
            case AIEvent.ET_VEHICLE_LOST:
                event = AIEventVehicleLost.Convert(event);
                local vehicle_id = event.GetVehicleID();
                for (local order_pos = 0; order_pos < AIOrder.GetOrderCount(vehicle_id); ++order_pos)
                {
                    AIOrder.RemoveOrder(vehicle_id, order_pos);
                }
                AIVehicle.SendVehicleToDepot(vehicle_id);
                break;

            // On vehicle crash, remove the vehicle from its towns vehicle list
            case AIEvent.ET_VEHICLE_CRASHED:
                event = AIEventVehicleCrashed.Convert(event);
                local vehicle_id = event.GetVehicleID();
                foreach (town_id, town in this.towns)
                {
                    if (town.RemoveVehicle(vehicle_id))
                        break;
                }
                break;

            default:
                break;
		}
	}
}

function CityLife::AskForMoney()
{
    local bank_balance = AICompany.GetBankBalance(AICompany.COMPANY_SELF);
    local loan_amount = AICompany.GetLoanAmount();
    local max_loan_amount = AICompany.GetMaxLoanAmount();
    AILog.Info("max_loan_amount: " + max_loan_amount);
    AILog.Info("bank balance: " + bank_balance);
    max_loan_amount = max_loan_amount > 500000 ? max_loan_amount : 500000;
    if (loan_amount > 0 && bank_balance >= loan_amount)
    {
        AICompany.SetLoanAmount(0);
        bank_balance -= loan_amount;
    }

    AILog.Info("max loan amount: " + max_loan_amount);
    AILog.Info("bank balance: " + bank_balance);

    if (bank_balance < max_loan_amount)
    {
        AIToyLib.ToyAskMoney(max_loan_amount - bank_balance);
        AILog.Info("I am once again asking for your financial support of " + (max_loan_amount - bank_balance));
    }
}

function CityLife::CreateTownList()
{
    local towns_list = AITownList();
    local towns_array = {};

    foreach (t, _ in towns_list)
    {
        towns_array[t] <- Town(t, this.load_saved_data);
	}

    return towns_array;
}

function CityLife::MonthlyManageTowns()
{
    foreach (_, town in this.towns)
    {
        town.MonthlyManageTown();
	}
}

function CityLife::ManageTown(town)
{
    town.ManageTown();
}

//disabled on 2.3 ver until fixed
function CityLife::MonthlyManageRoadBuilder()
{
    if (this.duplicit_ai)
        return;

    this.road_builder.Init(this.towns);
}

//disabled on 2.3 ver until fixed
function CityLife::ManageRoadBuilder()
{
    if (this.road_builder.FindPath(this.towns))
    {
        this.road_builder.BuildRoad(this.towns);
        this.towns[this.road_builder.town_a].Parade(this.towns[this.road_builder.town_b]);
    }
}

function CityLife::Save()
{
    AILog.Info("Saving data...");
    local save_table = {};

    /* If the script isn't yet initialized, we can't retrieve data
	 * from Town instances. Thus, simply use the original
	 * loaded table. Otherwise we build the table with town data.
	 */
    save_table.town_data_table <- {};
    if (!this.ai_init_done)
    {
        save_table.town_data_table <- ::TownDataTable;
    }
    else
    {
        save_table.duplicit_ai <- this.duplicit_ai;
        foreach (town_id, town in this.towns)
        {
            save_table.town_data_table[town_id] <- town.SaveTownData();
        }
        // Also store a savegame version flag
        save_table.save_version <- this.current_save_version;
    }

    return save_table;
}

function CityLife::Load(version, saved_data)
{
    if ((saved_data.rawin("save_version") && saved_data.save_version == this.current_save_version))
    {
        this.load_saved_data = true;
        foreach (townid, town_data in saved_data.town_data_table)
        {
			::TownDataTable[townid] <- town_data;
		}
        this.duplicit_ai = saved_data.duplicit_ai;
    }
    else
    {
		AILog.Info("Data format doesn't match with current version. Resetting.");
	}
}
