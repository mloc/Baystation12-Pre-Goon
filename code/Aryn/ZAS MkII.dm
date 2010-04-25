/*
Zoned
Air
System
MkII

To Do:
[ ]Merging
[X]Splitting
[X]Fire
[*]Airflow
*/

var/do_merges = 1 //Set this to 1 to test merging of zones.

var/const/FULL_PRESSURE = 3600000
//The pressure of a zone is 100% if each turf contains this amount of gas.
#define DOOR_CONNECTION_FLOW 50
//This value is the flow rate (as %) that will be used when a door is open between zones.
#define TILE_CONNECTION_FLOW 65
//This value is the flow rate (as %) that will be used when an entire floor tile connects two zones.

var/list
	gas_defaults = list("O2" = 756000,"Plasma" = 0,"CO2" = 0,"N2" = 2844000,"N2O" = 0,"Indicator" = 0)
	//This list contains the gas amounts per turf in contents new zones will have.
	//You can add new types of gases at any time by adding an entry to this list.
	//It is recommended that all possible gas types be defined in the list at compile-time, however.

	directional_types = list(/obj/machinery/door/window,/obj/window)
	//Any types in this list are considered the same as a side window or door.

var/zas_cycle = 2
//The amount of ticks an air cycle will last. Change in case of lag.
client/proc
	Set_ZAS_Cycle_Time(n as num)
		set category = "ZAS"
		n = max(1,n)
		zas_cycle = n
		world.log << "Zones will now update every [n] ticks."

var/manual_calc = 0

var/moving_zone = 0
//Switched on during large-scale room movement, e.g. engine ejection, to reduce checking lag.
//Keeping this on when such things are not happening causes construction and destruction not to register, leading to bugs.

var/list/zones = list()
//All the zones in the game are kept here, so that they are not deleted immediately after creation.

zone


	var
		update = 1 //Setting this to zero cancels updating for this zone. Update() needs to be spawned if this is reset to 1.
		list
			contents //The objects affected by this zone in a list. Usually turfs, but in pipe-zones, these are objs.

			gases //Contains the gas types and values of this zone in an associated list.
			gas_cache //Contains old values of gases
			turf_cache //Contains cached per_turf values.

			connections = list() //The zones connected to this one and the turfs between them in an associated list.
			connection_cache = list() //A list storing the percentage of flow to the zones in connections.

			updated_connections = list() //The zones that have already had flow calculated for them.

			zones_to_split //fills up when multiple doors to different zones close at once, as in a lockdown.
			zones_to_merge //fills up when multiple doors to different zones open.
			//Both of the previous variables are emptied at the end of a new cycle, and the contents merged into
			//or split from this zone.

			boundaries //contains the atoms which stopped the zone from proceeding.

		contents_cache = 0 //The cached length of the contents list.
		total_cache = 0 //The cache storing the total gas of this area.

		plasma_overlay = 0 //These track whether plasma and N2O overlays were applied.
		n2o_overlay = 0

		speakmychild = 0

		temp = T20C


	New(turf/start,door) //The extra argument, door, determines whether this is a mini-zone generated by closed airlocks.
		zones += src     //If 1, the zone encompasses all doorways adjacent to the start. If 2, it only fills the start area.
		if(start.zone)
			gases = start.zone.gases.Copy()
		else if(start.oxygen != O2STANDARD)
			gases = list("O2" = start.oxygen,"Plasma" = 0,"CO2" = start.co2,"N2" = start.n2,"N2O" = 0,"Indicator" = 0)
		else
			gases = gas_defaults.Copy() //If 0, the zone will fill as normal.
		if(door < 2)
			var/r_list = GetZone(start,door)
			contents = r_list[1]
			boundaries = r_list[2]
		else
			contents = list(start)
			boundaries = GetCardinals(start)
		if(!contents.len)
			del src
		for(var/turf/T in contents)
			T.zone = src
		for(var/G in gases)
			gases[G] *= contents.len
		var/turf/space/S = locate() in contents
		if(S)
			for(var/g in gases)
				gases[g] = 0
		rebuild_cache()

		spawn Update()

	proc

		Update()
		//Called every air cycle to check on things.
			while(update)

				sleep(zas_cycle)

				var/turf/space/S = locate() in contents
				if(S)
					for(var/g in gases)
						gases[g]=0
					for(var/turf/T in contents)
						T.poison = 0
						T.sl_gas = 0

				if(src in connections)
					RemoveAllConnections(src)
					connections -= src

				sleep(-1)

				var/t_gas
				for(var/g in gases)
					if(gases[g] != gas_cache[g])
						gas_cache[g] = gases[g]
						turf_cache[g] = gases[g] / contents.len
					t_gas += turf_cache[g]
				total_cache = t_gas


				if(contents_cache != contents.len)
					rebuild_cache()

				if(!contents.len) del src

				for(var/turf/T in contents)

					if(!T.accept_zoning)
						for(var/g in gases)
							gases[g] /= contents.len
						SubtractTurfs(T)
						for(var/g in gases)
							gases[g] *= contents.len

				sleep(-1)

				if(zones_to_split)
					SplitList(zones_to_split)
					zones_to_split = null

				if(zones_to_merge)
					MergeList(zones_to_merge)
					zones_to_merge = null

				for(var/zone/Z in connections)
					//Gases flow between connected zones on a per-turf concentration gradient.

					var/flow = connection_cache[Z]
					if(!flow) continue

					var/gas_diff = pressure() - Z.pressure()
					if(gas_diff > AF_MOVEMENT_THRESHOLD)// && more_air_here)
						Airflow(src,Z,gas_diff)


					for(var/g in gases)
						var/theo = (gases[g] + Z.gases[g]) / (contents.len + Z.contents.len)
						var
							diff_a = per_turf(g) - theo
							diff_b = Z.per_turf(g) - theo
						diff_a *= 1 - (flow / 100)
						diff_b *= 1 - (flow / 100)
						GasPerTurf(g,diff_a+theo)
						Z.GasPerTurf(g,diff_b+theo)
						//more_air_here += gases[g] - Z.gases[g]

					if(do_merges)
						if(OpenConnection(src,Z))
							var/merge = 1
							for(var/g in gases)
								if(!within_decimal_places(per_turf(g),Z.per_turf(g),50)) merge = 0
							if(merge)
								//world << "LOLWTF"
								RemoveAllConnections(Z)
								AddMerge(Z)
					//The average amount of airflow difference a zone at 1atm has to space is 150000

				sleep(-1)

				if (per_turf("Plasma") > 100000.0)
					if(!plasma_overlay)
						for(var/turf/T in contents)
							T.overlays.Add( plmaster )
						plasma_overlay = 1
				else if(plasma_overlay)
					for(var/turf/T in contents)
						T.overlays.Remove( plmaster )
					plasma_overlay = 0
				if (per_turf("N2O") > 100000.0)
					if(!n2o_overlay)
						for(var/turf/T in contents)
							T.overlays.Add( slmaster )
						n2o_overlay = 1
				else if(n2o_overlay)
					for(var/turf/T in contents)
						T.overlays.Remove( slmaster )
					n2o_overlay = 0

				if(pressure() > 500)
					update = 0
					CRASH("It's over NINE THOUSAAAAAND!")
					for(var/turf/T in contents)
						T.overlays += 'Connect.dmi'

		rebuild_cache(x)
			if(!contents.len) return 0
			total_cache = 0
			if(!turf_cache)
				turf_cache = gases.Copy()
			if(!gas_cache)
				gas_cache = gases.Copy()
			//if(x) //world << "LOLCache"
			for(var/g in gases)
				turf_cache[g] = gases[g] / contents.len
				//if(x) //world << "[gases[g]] > [turf_cache[g]]"
				total_cache += gases[g] / contents.len
				gas_cache[g] = gases[g]
			contents_cache = contents.len
			//if(x) //world << "[contents_cache]contents."


		CheckSplit(turf/T) //This check does basic airtightness checks on the eight tiles surrounding it.
			////world << "Checking for splitting."
			var
				S1 = get_step(T,NORTH)
				S2 = get_step(T,SOUTH)
				S3 = get_step(T,EAST)
				S4 = get_step(T,WEST)
			if(!Airtight(S1,T) && !Airtight(S2,T))
				var/list
					S1L = GetZone(S1)
					S2L = GetZone(S2)
				if(S1L.len && S2L.len)
					for(var/turf/X in S1L)
						if(X in S2L)
							S1L -= X
							S2L -= X
					if(S1L.len)
						AddSplit(S1)
						. = 1
					if(S2L.len)
						AddSplit(S2)
						. = 1
			if(!Airtight(S3,T) && !Airtight(S4,T))
				var/list
					S3L = GetZone(S3)
					S4L = GetZone(S4)
				if(S3L.len && S4L.len)
					for(var/turf/X in S3L)
						if(X in S4L)
							S3L -= X
							S4L -= X
					if(S3L.len)
						AddSplit(S3)
						. = 1
					if(S4L.len)
						AddSplit(S4)
						. = 1

		AddMerge(zone/Z)
		//Adds zone Z to the zones_to_merge list, allowing the zone to be merged into this one.
		//This is the proc that objects should call if they merge a zone.
			//world << "Adding zone for merging..."
			if(!zones_to_merge)
				zones_to_merge = list()
			zones_to_merge += Z


		AddSplit(turf/T)
		//Adds turf T to the zones_to_split list, allowing the turf to be the source of a new zone split from this one.
		//This is the proc that objects should call if they split a zone.
			//////world << "Adding zone for splitting."
			if(!zones_to_split)
				zones_to_split = list()
			zones_to_split += T


		SplitList(list/L)
		//All the turfs in list L will create new child zones with the same per-turf concentrations as this one.
		//Used internally in Update() to clear zones_to_split.
			if(L.len)
				world << "Splitting..."
				for(var/atom/A)
					if(src in associations(A.connected_zones))
						spawn(1) ZoneSetup(A)
				var/list/old_gases = gases.Copy()
				for(var/g in old_gases)
					if(!contents.len)
						del src
						return
					else
						old_gases[g] /= contents.len
				for(var/turf/T in L)
					var/zone/Z = new(T)
					contents -= Z.contents //Subtract the contents of this zone from src's contents.
					for(var/turf/X in Z.contents)
						X.overlays.len = 0
						//X.overlays += 'Deny.dmi'
					//	spawn(4) X.overlays -= 'Deny.dmi'
					//////world << "Making equal concentrations."
					for(var/g in gases)
						Z.GasPerTurf(g,old_gases[g]) //Set the concentrations per turf as equal.
						GasPerTurf(g,old_gases[g])
					L -= T
					zones_to_split -= T


		MergeList(list/L)
		//All the zones in list L will add their contents and gas values to this one and be deleted.
		//Used internally in Update() to clear zones_to_merge.
			if(L.len)
				world << "Merging..."
				for(var/zone/Z in L)
					if(Z == src) continue //Do not merge with self!
					//world << "Pooling gas..."
					for(var/g in gases)
						gases[g] += Z.gases[g]
						//world << "[gas_cache[g]] += [Z.gases[g]] -> [gases[g]]"
						Z.gases[g] = 0
					//world << "Adding contents..."
					for(var/turf/T in Z.contents)
						//Z.SubtractTurfs(T)
						//AddTurfs(T)
						Z.contents -= T
						contents += T
						T.zone = src
						//T.overlays += 'Confirm.dmi'
						//spawn(4) T.overlays -= 'Confirm.dmi'
					//overlayed_gases.Add(Z.overlayed_gases)
					connections.Add(Z.connections)
					connection_cache.Add(Z.connection_cache)
					updated_connections.Add(Z.updated_connections)
					rebuild_cache()
					//world << "Done."
					del Z


		AddTurfs(turf/T)
		//Adds all the turfs in the arg list to the zone, and assumes no gases are contained within them.
			if(isturf(T))
				contents += T
				T.zone = src
				if(T.zone.plasma_overlay)
					T.overlays += plmaster
				if(T.zone.n2o_overlay)
					T.overlays += slmaster

		SubtractTurfs(turf/T)
		//The reverse of AddTurfs(). This proc removes turfs from the contents, and displaces their gas values into this zone.
			contents -= T
			T.zone = null
			T.overlays -= slmaster
			T.overlays -= plmaster

		GasPerTurf(g,n)
		//Sets the total amount of gas g to n * length(contents).
		//Used to set per-tile concentration when splitting.
			. = n * contents.len
			if(. < 0.001)
				gases[g] = 0
				gas_cache[g] = 0
				turf_cache[g] = 0
			else
				gases[g] = .
				gas_cache[g] = .
				turf_cache[g] = n

		AddPerTurf(g,n)
			if(!(g in gases)) gases += g
			gases[g] += n * contents_cache
			if(gases[g] < 0.001) gases[g] = 0

		per_turf(g)
		//Returns the amount of this gas distributed over the turfs contained by the zone.
		//This is the amount of gas each tile of the zone would contain were the gases tracked by turf alone.
			if(g) return turf_cache[g]
			else return total_cache
		bc_per_turf(g)
			if(!contents.len) return 0
			if(g in gases)
				. = gases[g] / contents.len
			else if (!g)
				for(g in gases)
					. += gases[g] / contents.len
			else
				. = 0

		concentration(g)
		//Returns the amount of gas g divided by the turfs in the zone * FULL_PRESSURE.
		//This is the percentage of the zone's capacity taken up by gases of type g.
			if(!contents.len) return 0
			if(g in gases)
				. = (gases[g] / (contents.len * FULL_PRESSURE)) * pressure()//(contents.len * FULL_PRESSURE)
				//. *= 100
			else
				. = 0

		partial_pressure(g)
		//Returns units of gas g over units of all gases.
		//This is the percentage of the gases in the zone that are of type g.
			var/total = total()
			if(!total) return 0
			if(g in gases)
				. = gases[g] / total
				. *= 100
			else
				. = 0

		pressure()
		//Returns pressure as a percent value.
		//100% is reached when all the gases add up to the turfs in the zone * FULL_PRESSURE.
		//This is the percentage of the zone's capacity filled by all gases in the zone.
			if(!contents.len) return 0
			. = total() / (contents.len * FULL_PRESSURE)
			. *= 100

		total()
		//Returns the sum of all gas values.
			for(var/g in gases)
				. += gases[g]

proc
	/*
	One can think of zone connections as like valves determining flow between still-separate zones.

	If there is no anticipation of disconnecting zones, e.g. no door that separates two rooms, and they have
	roughly equal gas values, they merge instead, forming one new zone.
	*/


	AddConnection(zone/A,turf/T,zone/B)
	//Takes three arguments: two zones, A and B, to be connected, and the turf they are connected by.
	//Connects two unconnected zones to eachother, allowing gases to pass between them at a set rate.
		//world << "Adding a connection turf... Z[zones.Find(A)] [T]([T.x],[T.y]) Z[zones.Find(B)]"
		if(!istype(A,/zone) || !istype(B,/zone)) return
		if(!(A in B.connections) && !(B in A.connections))
			A.connections += B
			A.connection_cache += B
			B.connections += A
			B.connection_cache += A
			A.connections[B] = list(T)
			B.connections[A] = list(T)
		else
			if(T in A.connections[B]) return
			A.connections[B] += T
			B.connections[A] += T
		if(!HasDoors(T))
			A.connection_cache[B] += TILE_CONNECTION_FLOW
			B.connection_cache[A] += TILE_CONNECTION_FLOW
		else
			A.connection_cache[B] += DOOR_CONNECTION_FLOW
			B.connection_cache[A] += DOOR_CONNECTION_FLOW

	RemoveConnection(zone/A,turf/T,zone/B)
		//world << "Removing a connection turf... Z[zones.Find(A)] [T]([T.x],[T.y]) Z[zones.Find(B)]"
		if(!istype(A,/zone) || !istype(B,/zone))
			//world << "Foolish mortal! Either [A] or [B] is not a zone at all!"
			return
		if(!A in B.connections)
			//world << "Z[zones.Find(B)] does not have Z[zones.Find(A)] in it's list."
			return
		if(!B in A.connections)
			//world << "Z[zones.Find(B)] does not have Z[zones.Find(A)] in it's list."
			return
		if(A == B)
			//world << "What the hell, man? Connecting a zone to itself? That's just low."
			return
		if(!(T in A.connections[B]))
			//world << "It is indeed as I feared. The zone is removing a turf which is not there."
			return
		A.connections[B] -= T
		B.connections[A] -= T
		if(!length(A.connections[B]) || !length(B.connections[A]))
			//world << "Connection removed."
			A.connections -= B
			B.connections -= A
			A.connection_cache -= B
			B.connection_cache -= A
			return
		if(!HasDoors(T))
			A.connection_cache[B] -= TILE_CONNECTION_FLOW
			B.connection_cache[A] -= TILE_CONNECTION_FLOW
		else
			A.connection_cache[B] -= DOOR_CONNECTION_FLOW
			B.connection_cache[A] -= DOOR_CONNECTION_FLOW
		if(T in A.connections[B]) RemoveConnection(A,T,B)
		//world << "Done."

	RemoveAllConnections(zone/A,zone/B)
	//Takes three arguments: two zones, A and B, to be connected, and the turf they are connected by.
	//Removes a turf from the connection list, separating the zones if none remain.
		for(var/turf/T in A.connections[B])
			A.connections[B] -= T
			B.connections[A] -= T
			if(!length(A.connections[B]) || !length(B.connections[A]))
				A.connections -= B
				B.connections -= A
				A.connection_cache -= B
				B.connection_cache -= A
				return
			if(!HasDoors(T))
				A.connection_cache[B] -= TILE_CONNECTION_FLOW
				B.connection_cache[A] -= TILE_CONNECTION_FLOW
			else
				A.connection_cache[B] -= DOOR_CONNECTION_FLOW
				B.connection_cache[A] -= DOOR_CONNECTION_FLOW

	HasDoors(turf/T)
		var
			obj/machinery/door/D = locate() in T
			turf/station/wall/F = locate() in T
		if(F || D) return 1
		return 0

	ShowZone(zone/Z)
		if(!istype(Z,/zone)) return
		for(var/turf/T)
			T.overlays -= 'Zone.dmi'
			T.overlays -= 'Connect.dmi'
		for(var/turf/T in Z.contents)
			T.overlays += 'Zone.dmi'
		for(var/zone/A in Z.connections)
			if(!(Z.connections[A])) continue
			for(var/turf/T in A.contents)
				T.overlays += 'Connect.dmi'

	OpenConnection(zone/A,zone/B)
		if(!(B in A.connections)) return 0
		for(var/turf/T in A.connections[B])
			if(!HasDoors(T)) return 1
		return 0

turf


	var
		zone/zone
		is_connection = 0 //This variable is an indicator of whether this turf connects two zones, e.g. a doorway.
		accept_zoning = -1
		/*
		1 = Always Zone
		0 = Never Zone
		-1 = Zone According To Turf Density
		*/
	New()
		if(accept_zoning < 0)
			accept_zoning = !density
		. = ..()
		if(world.time > 10)
			////world << "New turf: [type]"
			//if(moving_zone) return .
			if(zone)
				for(var/turf/space/S in view(src,1))
					if(!Zonetight(S,src))
						S.zone = zone
						zone.contents += S
			if(!moving_zone)
				if(!accept_zoning)
					CloseWall(src)
				else
					OpenWall(src)



proc/GetZone(turf/T,ignore_doors=0) //This proc does the floodfill process to add the zone contents and boundaries.
	var/AT = Zonetight(T)
	var/list
		LA = list()
		LB = list()
	LA += T
	var/borders = list()
	borders += T
	var/end_loop = 0
	while(!end_loop)
		end_loop = 1
		for(var/turf/X in borders)
			if(Zonetight(X) != AT)
				borders -= X
				LB += X
				continue
			var/list/next = GetCardinals(X,1+ignore_doors)
			for(var/turf/Y in next)
				if(Y in LA) continue
				if(!CheckSpace(Y)) continue
				if(Zonetight(Y,X) != AT) continue
				LA += Y
				borders += Y
				end_loop = 0
			for(var/turf/Z in GetCardinals(X))
				if(!(Z in next))
					LB += Z
			borders -= X
	return list(LA,LB)

/*proc/sign(n) //A standard function returning the sign (+1,-1, or 0) of a number.
	if(n > 0) return 1
	else if(n < 0) return -1
	else return 0*/

proc/within_decimal_places(x,y,n)
	if((x > y - n && x < y + n)) return 1



proc/GetCardinals(turf/T,dir_blocked) //This proc returns a list of the turfs in cardinal directions from the source.
	. = list()
	. += get_step(T,NORTH)
	. += get_step(T,SOUTH)
	. += get_step(T,EAST)
	. += get_step(T,WEST)
	if(dir_blocked)                  //If dir_blocked is one, excludes airtight turfs. If two, still includes doors.
		for(var/turf/X in .)
			if(dir_blocked < 2)
				if(Zonetight(X,T)) . -= X
			else if(dir_blocked < 3)
				if(DirBlock(X,T) || !X.accept_zoning) . -= X
			else
				if(DirBlock(X,T) || !X.accept_zoning) . -= X
				for(var/atom/A in X)
					if(A.block_zoning && !A.is_open) . -= X

proc/GetDiagonals(turf/T,dir_blocked) //This proc returns a list of the turfs in diagonal directions from the source.
	. = list()
	. += get_step(T,NORTHWEST)
	. += get_step(T,SOUTHWEST)
	. += get_step(T,NORTHEAST)
	. += get_step(T,SOUTHEAST)
	if(dir_blocked)                  //If dir_blocked is nonzero, it will exclude airtight turfs.
		for(var/turf/X in .)
			if(Zonetight(X,T)) . -= X


proc/Dense(turf/T) //This function determines whether a tile has dense objects in it.
	if(!isturf(T)) return 1
	if(T.density) return 1
	for(var/atom/A in T)
		if(A.density) return 1
	return 0

proc/Blocked(turf/T) //This function is like Dense(), but bases its decision on turf/accept_zoning and atom/block_zoning.
	if(!isturf(T)) return 1
	if(!T.accept_zoning) return 1
	for(var/atom/A in T)
		if(A.type in directional_types) continue
		if(A.block_zoning) return 1
	return 0

proc/PracBlocked(turf/T) //This function is like Blocked() but considers open doors non-blocked.
	if(!isturf(T)) return 1
	if(!T.accept_zoning) return 1
	for(var/atom/A in T)
		if(A.type in directional_types) continue
		if(A.block_zoning && !A.is_open) return 1
	return 0

proc/DirBlock(turf/X,turf/Y,block) //This function determines whether a given turf is blocked by windows when moving from another.
	//return DirBlocked(X,get_dir(X,Y)) + DirBlocked(Y,get_dir(Y,X))
	if(!isturf(X) || !isturf(Y)) return 1
	if(!block)                     //The function can be used with dir_density checks or without.
		for(var/obj/D in X)
			if(D.type in directional_types)
				var/d = D.dir
				if(istype(D,/obj/machinery/door/window))
					//if(D.is_open) continue
					if(D.dir == NORTH || D.dir == SOUTH) d = EAST
					else d = SOUTH
				if(d == SOUTHWEST) return D
				if(d == get_dir(X,Y) && !D.is_open) return D
		for(var/obj/D in Y)
			if(D.type in directional_types)
				var/d = D.dir
				if(istype(D,/obj/machinery/door/window))
					//if(D.is_open) continue
					if(D.dir == NORTH || D.dir == SOUTH) d = EAST
					else d = SOUTH
				if(d == SOUTHWEST) return D
				if(d == get_dir(Y,X) && !D.is_open) return D
	else
		for(var/obj/D in X)
			if(D.type in directional_types)
				var/d = D.dir
				if(istype(D,/obj/machinery/door/window))
					if(D.dir == NORTH || D.dir == SOUTH) d = EAST
					else d = SOUTH
				if(d == SOUTHWEST) return D
				if(d == get_dir(X,Y)) return D
		for(var/obj/D in Y)
			if(D.type in directional_types)
				var/d = D.dir
				if(istype(D,/obj/machinery/door/window))
					if(D.dir == NORTH || D.dir == SOUTH) d = EAST
					else d = SOUTH
				if(d == SOUTHWEST) return D
				if(d == get_dir(Y,X)) return D
	return 0

proc/Zonetight(turf/X,turf/Y) //This uses Blocked() and DirBlock() in combination to determine whether a tile blocks GetZone from another.
	if(!isturf(X)) return 1
	. = Blocked(X)
	if(Y && !.)
		. = DirBlock(X,Y,1)

proc/Airtight(turf/X,turf/Y) //This uses Blocked() and DirBlock() in combination to determine whether a tile blocks air from another.
	if(!isturf(X)) return 1
	. = PracBlocked(X)
	if(Y && !.)
		. = DirBlock(X,Y)

proc/CheckSpace(turf/S)
	if(!istype(S,/turf/space)) return 1
	for(var/turf/T in range(S,2))
		if(!istype(T,/turf/space)) return 1



atom/var/block_zoning = 0 //When 1, this atom blocks zoning, making it essentially airtight.
atom/var/flow_reduction = 0 //This value is the percent flow to subtract from the standard when this object is in a connection turf.
                            //For example, a grill could reduce the flow rate into space by half when present.
atom/var/is_door = 0 //Self explanatory. Used in door-zone and fire checks.
atom/var/is_open = 0 //Used in fire checks.
obj/var/dir_density = 1 //Used for directional objects.

mob/block_zoning = 0
mob/is_open = 1

atom/var/list/connected_zones //If this is an object which becomes airtight frequently, these are zones it connects.
proc

	OpenDoor(atom/A) //This is called when a door is opened between two zones, to connect them.
		////world << "Opening door..."
		if(moving_zone) return
		A.is_open = 1
		if(!A.connected_zones || null_entries(A.connected_zones))
			ZoneSetup(A)
			////world << "Set up zones. [A.connected_zones.len]"
		//if(!istype(A,/obj/directional))
		//	var/zone/ZA = A.connected_zones[1]
		//	if(!isturf(A))
		//		ZA.AddTurfs(A.loc)
		//	else
		///		ZA.AddTurfs(A)
		var/turf/T = A.loc
		if(isturf(A)) T = A
		for(var/turf/C in A.connected_zones)
			////world << "Connected zone [A.connected_zones.Find(C)]."
			AddConnection(C.zone,T,T.zone)
		for(var/turf/C in A.connected_zones)
			for(var/turf/D in A.connected_zones)
				if(C.zone == D.zone) continue
				AddConnection(C.zone,T,D.zone)
		if(istype(A,/obj/machinery/door/window))
			A:dir_density = 0

	CloseDoor(atom/A) //This is called when a door is closed between two zones, to subtract the flow.
		if(moving_zone) return
		A.is_open = 0
		////world << "Closing Door"
		if(!A.connected_zones || null_entries(A.connected_zones))
			ZoneSetup(A)
		//if(!istype(A,/obj/directional))
		//	var/zone/ZA = A.connected_zones[1]
		//	if(!isturf(A))
		///		ZA.SubtractTurfs(A.loc)
		//	else
		//		ZA.SubtractTurfs(A)
		var/turf/T = A.loc
		if(isturf(A)) T = A
		for(var/turf/C in A.connected_zones)
			////world << "Disonnected zone [A.connected_zones.Find(C)]."
			RemoveConnection(C.zone,T,T.zone)
		for(var/turf/C in A.connected_zones)
			for(var/turf/D in A.connected_zones)
				if(C == D) continue
				RemoveConnection(C.zone,T,D.zone)
		if(istype(A,/obj/machinery/door/window))
			A:dir_density = 1

	ZoneSetup(atom/A) //This sets up the door's zone variables. If two valid zones are found, returns 1, otherwise 0.

		if(moving_zone) return

		////world << "Setting up zones for [A]"

		var/turf/C

		if(isturf(A)) C = A
		else C = A.loc

		if(!C.zone)
			new/zone(C,1)

		A.connected_zones = list()

		if(A.type in directional_types)
			////world << "Connector uses directional blocking."
			var/d = A.dir
			if(istype(A,/obj/machinery/door/window))
				if(d == NORTH || d == SOUTH) d = EAST
				else d = SOUTH
			var/turf/T = get_step(A.loc,d)
			if(!(T in A.connected_zones))
				A.connected_zones = list(T)
			return 1

		var/abz = A.block_zoning
		var/aaz = -1
		if(isturf(A))
			aaz = A:accept_zoning
			A:accept_zoning = 1
		A.block_zoning = 0

		var/turf/X = A.loc
		if(isturf(A)) X = A

		var/list/turfs = GetCardinals(X)
		for(var/turf/N in turfs)
			if(Airtight(N,X)) turfs -= N

		for(var/turf/T in turfs)
			if(T.zone == C.zone) continue

			if(!(T.zone in associations(A.connected_zones)) && T.zone)
				if(!(T in A.connected_zones)) A.connected_zones += T
				A.connected_zones[T] = T.zone

				//AddConnection(T.zone,C,C.zone)

		A.block_zoning = abz
		if(isturf(A)) A:accept_zoning = aaz
		return 1

	OpenWall(atom/A)
		////world << "Opening wall..."
		if(moving_zone) return
		var/turf/T = A.loc
		if(isturf(A)) T = A
		if(Blocked(T)) return
		if(!T.zone) new/zone(T,2)
		return OpenDoor(A)

	CloseWall(atom/A)
		////world << "Closing wall..."
		if(moving_zone) return
		if(!A.connected_zones || null_entries(A.connected_zones))
			ZoneSetup(A)
		if(A.connected_zones.len)
			////world << "A.connected_zones.len : [A.connected_zones.len]"
			var/turf/T = A.connected_zones[1]
			var/zone/ZA = T.zone
			if(A.connected_zones.len == 1)
				ZA.CheckSplit(A)
			CloseDoor(A)
	TurnWindow(obj/window/W,ndir)
		//world << "<u>Window turned: [W]([W.x],[W.y])</u>"
		if(ndir == W.dir) return
		if(moving_zone) return
		var
			needs_merge = 0
			needs_split = 0
			odir = W.dir
			turf
				T = W.loc
				A = get_step(T,odir)
				B = get_step(T,ndir)

		W.loc = null
		//world << "So far, we've determined that T = [T], A = [A], and the direction is [odir]."
		//world << "In addition, B = [B], and ndir = [ndir]."

		if(WinCheck(T,odir))
			//world << "I say, this does indeed need a merge at once!"
			needs_merge = 1
			for(var/obj/window/N in T)
				if(N == W) continue
				if(N.dir == odir)
					//world << "Well,actually not."
					needs_merge = 0
		if(WinCheck(T,ndir))
			//world << "I say, this does indeed need a split at once!"
			needs_split = 1
			for(var/obj/window/N in T)
				if(N == W) continue
				if(N.dir == ndir)
					//world << "Well, actually not."
					needs_split = 0
		if(needs_merge)
			//world << "Applied a merge, good sir!"
			AddConnection(T.zone,T,A.zone)
		if(needs_split)
			if(B.zone == T.zone)
				//world << "Applied a split, good sir!"
				T.zone.CheckSplit(B)
			else
				//world << "HAH! Merely a removal of connection."
				RemoveConnection(T.zone,T,B.zone)
				RemoveConnection(T.zone,B,B.zone)
		W.loc = T

	MoveWindow(obj/window/W,turf/nloc)
		//world << "<u>Window moved: [W]([W.x],[W.y])</u>"
		if(nloc == W.loc) return
		if(moving_zone) return
		var
			needs_merge = 0
			needs_split = 0
			odir = W.dir
			turf
				T = W.loc
				A = get_step(T,odir)
				B = get_step(nloc,odir)

		W.loc = null
		//world << "So far, we've determined that T = [T], A = [A], and the direction is [odir]."
		//world << "In addition, B = [B], and nloc = [nloc]."

		if(WinCheck(T,odir))
			//world << "I say, this does indeed need a merge at once!"
			needs_merge = 1
		for(var/obj/window/N in T)
			if(N == W) continue
			if(N.dir == odir)
				//world << "Well,actually not."
				needs_merge = 0
		if(WinCheck(nloc,odir))
			//world << "I say, this does indeed need a split at once!"
			needs_split = 1
		for(var/obj/window/N in nloc)
			if(N == W) continue
			if(N.dir == odir)
				//world << "Well, actually not."
				needs_split = 0
		if(needs_merge)
			//world << "Applied a merge, good sir!"
			AddConnection(T.zone,T,A.zone)
		if(needs_split)
			if(B.zone == T.zone)
				//world << "Applied a split, good sir!"
				T.zone.CheckSplit(B)
			else
				//world << "HAH! Merely a removal of connection."
				RemoveConnection(T.zone,T,B.zone)
				RemoveConnection(T.zone,B,B.zone)

		W.loc = T
	DelWindow(obj/window/W)
		//world << "<u>Window deleted: [W]([W.x],[W.y])</u>"
		var
			needs_merge = 0
			odir = W.dir
			turf
				T = W.loc
				A = get_step(T,odir)

		//W.loc = null
		//world << "So far, we've determined that T = [T], A = [A], and the direction is [odir]."

		if(WinCheck(T,odir))
			//world << "I say, this does indeed need a merge at once!"
			needs_merge = 1
		for(var/obj/window/N in T)
			if(N == W) continue
			if(N.dir == odir)
				//world << "And yet, it does not."
				needs_merge = 0
		if(needs_merge)
			//world << "Applied, good sir!"
			AddConnection(T.zone,T,A.zone)

		//	W.loc = T
	NewWindow(obj/window/W)
		//world << "<u>Window created: [W]([W.x],[W.y])</u>"
		if(world.time < 10) return
		var
			needs_split = 0
			turf
				T = W.loc
				A = get_step(T,W.dir)

		if(moving_zone) return

		//W.loc = null

		if(WinCheck(T,W.dir)) needs_split = 1
		for(var/obj/window/N in T)
			if(N == W) continue
			if(N.dir == W.dir) needs_split = 0
		if(needs_split)
			if(A.zone == T.zone)
				T.zone.CheckSplit(A)
			else
				RemoveConnection(T.zone,T,A.zone)
				RemoveConnection(T.zone,A,A.zone)

		//W.loc = T

proc/associationlists(list/L)
	if(!L || !L.len) return list()
	var/list/K = list()
	for(var/i = 1,i <= L.len,i++)
		var/item = L[i]
		var/list/M = L[item]
		K.Add(M)
	. = K
proc/associations(list/L)
	. = associationlists(L)
proc/null_entries(list/L)
	for(var/item in L)
		if(!item) return 1