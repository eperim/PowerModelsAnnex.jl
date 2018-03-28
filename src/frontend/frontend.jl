module FrontEnd

using DataFrames
using PowerModels
using Memento
using Unitful
include("units.jl")
using .Units

export
    Network,
    add_bus!,
    add_gen!,
    add_load!,
    add_pi_load!,
    add_ps_load!,
    add_line!,
    add_cost_gen!,
    add_cost_load!,
    network2pmc,
    build_pmc!,
    converged

# These dictionaries store which quantities are relevant to us when building a network model.
# The keys are the titles of the columns we are going to use, while the values are the corresponding
# keys in a PowerModels network.
# Whenever we don't want to import a column from the PowerModels network, the dictionary establishes
# a default value to be used. Default value is `missing` for most quantites, except for status,
# for which we use `1`, meaning the element is on, and for `element_id`, for which we use -1

"""
    bus_columns

:element_id -> id number of the bus
:name ->  name of the bus
:voltage -> bus operating voltage
:volt_max -> maximum bus voltage
:volt_min -> minimum bus voltage
:bus_type -> What are the types? #TODO
:base_kv -> What is this? #TODO
:coords -> bus geocoordinates in latitude and longitude
"""
const bus_columns = Dict(
    :element_id => :index,
    :name => :bus_name,
    :voltage => :vm,
    :volt_max => :vmax,
    :volt_min => :vmin,
    :bus_type => :bus_type,
    :base_kv => :base_kv,
    :coords => missing, # The cases don't come with location data.
)

"""
    gen_columns

:element_id -> generator ID number
:bus -> ID of the bus where the generator is placed
:gen_p -> active power generated
:p_max -> maximum active power
:p_min -> minimum active power
:gen_q -> reactive power generated
:q_max -> maximum reactive power
:q_min -> minimum reactive power
:cost -> ID number of the associated cost
:startup_cost -> startup cost
:status -> 0=IDLE, 1=ACTIVE
:ramp -> 10-minute ramping constraint
"""
const gen_columns = Dict(
    :element_id => :index,
    :bus => :gen_bus,
    :gen_p => :pg, # Active power
    :p_max => :pmax,
    :p_min => :pmin,
    :gen_q => :qg, # Reactive power
    :q_max => :qmax,
    :q_min => :qmin,
    :cost => missing, # We don't want to store the cost function here, just its id.
    :startup_cost => :startup,
    :status => :gen_status,
    :ramp => :ramp_10,
)

"""
    pi_load_columns

:element_id -> ID number of the load
:bus -> ID number of the bus where the load is placed
:load -> active load value
:status -> 0=IDLE, 1=ACTIVE
"""
const pi_load_columns = Dict(
    :element_id => -1, # PowerModel cases blend loads into buses, so they have no unique index.
    :bus => :index,
    :load => :pd,
    :status => 1,
)

"""
    ps_load_columns

:element_id -> ID number of the load
:bus -> ID number of the bus where the load is placed
:load -> active load value
:load_max -> maximum active load
:cost -> ID number of the associated cost
:status -> 0=IDLE, 1=ACTIVE
"""
const ps_load_columns = Dict( # This is meant for our use, not for importing powermodels cases.
    :element_id => -1,
    :bus => missing,
    :load => missing, # Active power
    :load_max => missing,
    :cost => missing,
    :status => 1,
)

"""
    line_columns

:element_id -> ID number of the line
:rate_a -> maximum current under rate A
:rate_b -> maximum current under rate B
:rate_c -> maximum current under rate C
:transformer -> is transformer?
:from_bus -> first end-bus ID
:to_bus -> second end-bus ID
:status -> 0=IDLE, 1=ACTIVE
:resistance -> line electric resistance
:reactance -> line reactance
:susceptance -> line susceptance
:ang_min -> minimum voltage angle difference
:ang_max -> maximum voltage angle difference
"""
const line_columns = Dict(
    :element_id => :index,
    :rate_a => :rate_a,
    :rate_b => :rate_b,
    :rate_c => :rate_c,
    :transformer => :transformer,
    :from_bus => :f_bus,
    :to_bus => :t_bus,
    :status => :br_status,
    :resistance => :br_r,
    :reactance => :br_x,
    :susceptance => :br_b,
    :ang_min => :angmin,
    :ang_max => :angmax,
)

"""
    cost_columns

:element_id -> ID number of the cost
:coeffs -> coefficients of the cost function
"""
const cost_columns = Dict(
    :element_id => -1,
    :coeffs => :cost,
)

"""
    Network

Basic type for storing a network as a group of DataFrames plus a PowerModels network case.

- Constructors:

    Network(; bus, gen, pi_load, ps_load, line, cost_gen, cost_load, pmc)

Create a `Network` containing the specified dataframes. Specifying a PowerModel case `pmc`
will solely store the case inside the `Network`, without using it to populate the
dataframes. If that is desired, another constructor should be used.

    Network(pmc::Dict{String, Any})

Create a `Network` from a PowerModel network.

    Network(path::AbstractString)

Create a `Network` from a Matpower case file.

    Network(case::Symbol)

Create a `Network` from a case. All cases are stored inside the `case_library` folder. In
order to list all valid case names, use `PowerModelsAPI.list_cases()`.
"""
struct Network
    bus::DataFrame
    gen::DataFrame
    pi_load::DataFrame
    ps_load::DataFrame
    line::DataFrame
    cost_gen::DataFrame
    cost_load::DataFrame

    pmc::Dict{String,Any} # PowerModels case
    results::Dict{String,Any} # Results from OPF. Always start empty.

    function Network(;
            bus::DataFrame = DataFrame(
                [[] for i in 1:length(bus_columns)],
                sort(collect(keys(bus_columns)))
            ),
            gen::DataFrame = DataFrame(
                [[] for i in 1:length(gen_columns)],
                sort(collect(keys(gen_columns)))
            ),
            pi_load::DataFrame = DataFrame(
                [[] for i in 1:length(pi_load_columns)],
                sort(collect(keys(pi_load_columns)))
            ),
            ps_load::DataFrame = DataFrame(
                [[] for i in 1:length(ps_load_columns)],
                sort(collect(keys(ps_load_columns)))
            ),
            line::DataFrame = DataFrame(
                [[] for i in 1:length(line_columns)],
                sort(collect(keys(line_columns)))
            ),
            cost_gen::DataFrame = DataFrame(
                [[] for i in 1:length(cost_columns)],
                sort(collect(keys(cost_columns)))
            ),
            cost_load::DataFrame = DataFrame(
                [[] for i in 1:length(cost_columns)],
                sort(collect(keys(cost_columns)))
            ),
            pmc::Dict{String, Any} = Dict{String,Any}(),
            results::Dict{String, Any} = Dict{String,Any}(),
        )
        return new(bus, gen, pi_load, ps_load, line, cost_gen, cost_load, pmc, results)
    end
end


"""
    build_df_from_pmc(columns::Dict{Symbol, <: Any}, block::Dict{String,Any})

Return a DataFrame as built from a PowerModels case dictionary. `columns` specifies which
quantites to grab and from where. `block` corresponds to a dictionary from a PowerModels
case.
"""
function build_df_from_pmc(columns::Dict{Symbol, <: Any}, block::Dict{String,Any})
    entries = Dict()
    for k in keys(columns)
        if isa(columns[k], Symbol)
            s = string(columns[k])
            entries[k] = Vector{Any}( # This is necessary for to avoid having columns
            # initialized as `NAType` and thus refusing other types. Not ideal, though.
                    [(s in keys(block[i]) ? block[i][s] : missing) for i in keys(block)]
                )
        else
            entries[k] = fill(columns[k], length(block))
        end
    end
    return allowmissing!(DataFrame(entries))
end

function Network(pmc::Dict)
    gen_df = build_df_from_pmc(gen_columns, pmc["gen"])
    gen_df[:cost] = collect(1:size(gen_df)[1]) # Since the only place where costs are stored
    # in the pmc is in pmc["gen"], the order should automatically be preserved.
    allowmissing!(gen_df)
    cost_gen_df = build_df_from_pmc(cost_columns, pmc["gen"])
    cost_gen_df[:element_id] = collect(1:size(cost_gen_df)[1])
    allowmissing!(cost_gen_df)
    pi_load_df = build_df_from_pmc(pi_load_columns, pmc["bus"])
    # Some buses might not have load, so we must remove them from the load data frame.
    rows2delete = [i for i in 1:size(pi_load_df)[1] if (pi_load_df[:load][i] == 0)]
    deleterows!(pi_load_df, rows2delete)
    pi_load_df[:element_id] = collect(1:size(pi_load_df)[1])
    pi_load_df[:status] = fill(1, size(pi_load_df)[1])
    allowmissing!(pi_load_df)

    return Network(
        bus = build_df_from_pmc(bus_columns, pmc["bus"]),
        gen = gen_df,
        pi_load = pi_load_df,
        ps_load = DataFrame(
            [[] for i in 1:length(ps_load_columns)],
            sort(collect(keys(ps_load_columns)))
        ),
        line = build_df_from_pmc(line_columns, pmc["branch"]),
        cost_gen = cost_gen_df,
        cost_load = DataFrame(
            [[] for i in 1:length(cost_columns)],
            sort(collect(keys(cost_columns)))
        ),
        pmc = pmc,
        results = Dict{String,Any}(),
    )
    applyunits!(net)

    return net
end


"""
    applyunits!(net::Network)

This function annotates the Network structure with physical unit annotations.
For example, for the load column, it is originally in Float64. This function
will convert it to a type representing the units "u"MWh"). See Units.jl
for more information. We are assuming energy units as opposed to power units.
"""
function applyunits!(net::Network)
    net.pi_load[:load] = net.pi_load[:load]u"MWh"
    net.ps_load[:load] = net.ps_load[:load]u"MWh"
    net.ps_load[:load_max] = net.ps_load[:load_max]u"MWh"
    net.gen[:gen_p] = net.gen[:gen_p]u"MWh"
    net.gen[:p_max] = net.gen[:p_max]u"MWh"
    net.gen[:p_min] = net.gen[:p_min]u"MWh"
    net.gen[:gen_q] = net.gen[:gen_q]u"MVARh"
    net.gen[:q_max] = net.gen[:q_max]u"MVARh"
    net.gen[:q_min] = net.gen[:q_min]u"MVARh"
    net.gen[:startup_cost] = net.gen[:startup_cost]u"USD"
    net.gen[:ramp] = net.gen[:ramp]u"USD"
end

function stripunits!(net::Network)
    # Incomplete method to be extended as we annotate units
    net.pi_load[:load] = Array{Union{Missings.Missing,Float64}}(fustrip(net.pi_load[:load]))
end

function applyunits!(params::Dict{String, AbstractArray})
    # Incomplete method to be extended as we annotate units
    error("Not Implemented Yet")
end

function stripunits!(params::Dict{String, AbstractArray})
    # Incomplete method to be extended as we annotate unitss
    error("Not Implemented Yet")
end

function matpower2pmc(path::AbstractString)
    return setlevel!(getlogger(PowerModels), "error") do
        PowerModels.parse_file(path)
    end
end

function Network(casepath::AbstractString)
    return Network(matpower2pmc(casepath))
end

"""
    list_cases()

List all cases available in the case library.
"""
function list_cases()
    cases = readdir(CASE_LIB_PATH)
    cases = replace.(cases, ".m", "")
    cases = Symbol.(cases)
    return cases
end

"""
    add_bus!(
        net::Network;
        bus_type::Int=0,
        base_kv::Union{Missings.Missing,<:Number}=missing,
        name::AbstractString="none",
        element_id::Int=-1,
        voltage::Union{Missings.Missing,<:Number}=missing,
        volt_max::Union{Missings.Missing,<:Number}=missing,
        volt_min::Union{Missings.Missing,<:Number}=missing,
        coords::Union{Missings.Missing,Tuple{Float64,Float64}}=missing,
    )

Add a new bus to Network `net`. If `name` and `element_id` are not provided, reasonable
values will be automatically chosen.
"""
function add_bus!(
    net::Network;
    bus_type::Int=0,
    base_kv::Union{Missings.Missing,<:Number}=missing,
    name::AbstractString="none",
    element_id::Int=-1,
    voltage::Union{Missings.Missing,<:Number}=missing,
    volt_max::Union{Missings.Missing,<:Number}=missing,
    volt_min::Union{Missings.Missing,<:Number}=missing,
    coords::Union{Missings.Missing,Tuple{Float64,Float64}}=missing,
)
    ids = net.bus[:element_id]
    if element_id == -1 || element_id in ids
        control = false
        if element_id in ids
            w = "Desired bus id, $element_id, is already in use. "
            control = true
        end
        element_id = isempty(ids) ? 1 : maximum(ids) + 1
        if control
            warn(w * "Using id = $element_id instead.")
        end
    end
    name == "none" ? name = "bus_" * string(element_id) : nothing
    push!(
        net.bus,
        Any[base_kv, bus_type, coords, element_id, name, volt_max, volt_min, voltage]
    )
end

"""
    add_gen!(
        net::Network;
        element_id::Int=-1,
        bus::Union{Missings.Missing,Int}=missing,
        gen_p::Union{Missings.Missing,<:Number}=missing,
        p_max::Union{Missings.Missing,<:Number}=missing,
        p_min::Union{Missings.Missing,<:Number}=missing,
        gen_q::Union{Missings.Missing,<:Number}=missing,
        q_max::Union{Missings.Missing,<:Number}=missing,
        q_min::Union{Missings.Missing,<:Number}=missing,
        cost::Union{Missings.Missing,Int}=missing,
        startup_cost::Union{Missings.Missing,<:Number}=missing,
        status::Int= 1,
        ramp::Union{Missings.Missing,<:Number}=missing,
    )

Add a new generator to a Network `net`. In case `element_id` and `status` are not provided,
a reasonable value will be chosen for `element_id`, while `status` wil be assumed as `1`
(the element is active).
"""
function add_gen!(
    net::Network;
    element_id::Int=-1,
    bus::Union{Missings.Missing,Int}=missing,
    gen_p::Union{Missings.Missing,<:Number}=missing,
    p_max::Union{Missings.Missing,<:Number}=missing,
    p_min::Union{Missings.Missing,<:Number}=missing,
    gen_q::Union{Missings.Missing,<:Number}=missing,
    q_max::Union{Missings.Missing,<:Number}=missing,
    q_min::Union{Missings.Missing,<:Number}=missing,
    cost::Union{Missings.Missing,Int}=missing,
    startup_cost::Union{Missings.Missing,<:Number}=missing,
    status::Int= 1,
    ramp::Union{Missings.Missing,<:Number}=missing,
)
    ids = net.gen[:element_id]
    if element_id == -1 || element_id in ids
        control = false
        if element_id in ids
            w = "Desired bus id, $element_id, is already in use. "
            control = true
        end
        element_id = isempty(ids) ? 1 : maximum(ids) + 1
        if control
            warn(w * "Using id = $element_id instead.")
        end
    end
    push!(net.gen, (Any[
        bus,
        cost,
        element_id,
        gen_p,
        gen_q,
        p_max,
        p_min,
        q_max,
        q_min,
        ramp,
        startup_cost,
        status,
    ]))
end

"""
    add_pi_load!(
        net::Network;
        element_id::Int=-1,
        bus::Union{Missings.Missing,Int}=missing,
        load::Union{Missings.Missing,<:Number}=missing,
        status::Int=1,
    )

Add a new price insensitive load to a Network `net`. In case `element_id` and `status` are
not provided, a reasonable value will be chosen for `element_id`, while `status` wil be
assumed as `1` (the element is active).
"""
function add_pi_load!(
    net::Network;
    element_id::Int=-1,
    bus::Union{Missings.Missing,Int}=missing,
    load::Union{Missings.Missing,<:Number}=missing,
    status::Int=1,
)
    ids = net.pi_load[:element_id]
    if element_id == -1 || element_id in ids
        control = false
        if element_id in ids && element_id != -1
            w = "Desired bus id, $element_id, is already in use. "
            control = true
        end
        element_id = isempty(ids) ? 1 : maximum(ids) + 1
        if control
            warn(w * "Using id = $element_id instead.")
        end
    end
    push!(net.pi_load, Any[bus, element_id, load, status])
end

"""
    add_load!(
        net::Network;
        element_id::Int=-1,
        bus::Union{Missings.Missing,Int}=missing,
        load::Union{Missings.Missing,<:Number}=missing,
        status::Int=1,
    )

Add a new price insensitive load to a Network `net`. In case `element_id` and `status` are
not provided, a reasonable value will be chosen for `element_id`, while `status` wil be
assumed as `1` (the element is active).
"""
function add_load!(
    net::Network;
    element_id::Int=-1,
    bus::Union{Missings.Missing,Int}=missing,
    load::Union{Missings.Missing,<:Number}=missing,
    status::Int=1,
)
    add_pi_load!(net, element_id = element_id, bus = bus, load = load, status = status)
end


"""
    add_ps_load!(
        net::Network;
        element_id::Int=-1,
        bus::Union{Missings.Missing,Int}=missing,
        load::Union{Missings.Missing,<:Number}=missing,
        load_max::Union{Missings.Missing,<:Number}=missing,
        cost::Union{Missings.Missing,Int}=missing,
        status::Int=1,
    )

Add a new price sensitive load to a Network `net`. In case `element_id` and `status` are
not provided, a reasonable value will be chosen for `element_id`, while `status` wil be
assumed as `1` (the element is active).
"""
function add_ps_load!(
    net::Network;
    element_id::Int=-1,
    bus::Union{Missings.Missing,Int}=missing,
    load::Union{Missings.Missing,<:Number}=missing,
    load_max::Union{Missings.Missing,<:Number}=missing,
    cost::Union{Missings.Missing,Int}=missing,
    status::Int=1,
)
    ids = net.ps_load[:element_id]
    if element_id == -1 || element_id in ids
        control = false
        if element_id in ids && element_id != -1
            w = "Desired bus id, $element_id, is already in use. "
            control = true
        end
        element_id = isempty(ids) ? 1 : maximum(ids) + 1
        if control
            warn(w * "Using id = $element_id instead.")
        end
    end
    push!(net.ps_load, Any[bus, cost, element_id, load, load_max, status])
end

"""
    add_line!(
        net::Network;
        rate_a::Union{Missings.Missing,<:Number}= missing,
        rate_b::Union{Missings.Missing,<:Number}= missing,
        rate_c::Union{Missings.Missing,<:Number}= missing,
        transformer::Bool= false,
        from_bus::Union{Missings.Missing,Int}= missing,
        to_bus::Union{Missings.Missing,Int}= missing,
        status::Int=1,
        element_id::Int=-1,
        resistance::Union{Missings.Missing,<:Number}= missing,
        reactance::Union{Missings.Missing,<:Number}= missing,
        susceptance::Union{Missings.Missing,<:Number}= missing,
        ang_min::Float64=-1.0,
        ang_max::Float64=1.0,
    )

Add a new line to a Network `net`. In case `element_id`, `transformer` and `status` are
not provided, a reasonable value will be chosen for `element_id`, while `status` wil be
assumed as `1` (the element is active) and `transformer` will be assumed as `false` (the
line is not a transformer).
"""
function add_line!(
    net::Network;
    rate_a::Union{Missings.Missing,<:Number}= missing,
    rate_b::Union{Missings.Missing,<:Number}= missing,
    rate_c::Union{Missings.Missing,<:Number}= missing,
    transformer::Bool= false,
    from_bus::Union{Missings.Missing,Int}= missing,
    to_bus::Union{Missings.Missing,Int}= missing,
    status::Int=1,
    element_id::Int=-1,
    resistance::Union{Missings.Missing,<:Number}= missing,
    reactance::Union{Missings.Missing,<:Number}= missing,
    susceptance::Union{Missings.Missing,<:Number}= missing,
    ang_min::Float64=-1.0,
    ang_max::Float64=1.0,
)
    ids = net.line[:element_id]
    if element_id == -1 || element_id in ids
        control = false
        if element_id in ids
            w = "Desired line id, $element_id, is already in use. "
            control = true
        end
        element_id = isempty(ids) ? 1 : maximum(ids) + 1
        if control
            warn(w * "Using id = $element_id instead.")
        end
    end
    push!(net.line, Any[
        ang_max,
        ang_min,
        from_bus,
        element_id,
        rate_a,
        rate_b,
        rate_c,
        reactance,
        resistance,
        status,
        susceptance,
        to_bus,
        transformer,
    ])
end

"""
    add_cost_gen!(
        net::Network;
        coeffs::Vector{<:Real}=Vector{Float64}(),
        gen_id::Union{Missings.Missing,Int}= missing,
        element_id::Int= -1
    )

Add new generator cost to a Network `net`. If `element_id` is not specified, a reasonable
value will be adopted.
"""
function add_cost_gen!(
    net::Network;
    coeffs::Vector{<:Real}=Vector{Float64}(),
    gen_id::Union{Missings.Missing,Int}= missing,
    element_id::Int= -1
)
    ids = net.cost_gen[:element_id]
    if element_id == -1 || element_id in ids
        control = false
        if element_id in ids && element_id != -1
            w = "Desired bus id, $element_id, is already in use. "
            control = true
        end
        element_id = isempty(ids) ? 1 : maximum(ids) + 1
        if control
            warn(w * "Using id = $element_id instead.")
        end
    end
    if ismissing(gen_id)
        push!(net.cost_gen, Any[coeffs, element_id])
    else
        gen_ids = net.gen[:element_id]
        if gen_id in gen_ids
            push!(net.cost_gen, Any[coeffs, element_id])
            net.gen[Array{Bool}(net.gen[:element_id] .== gen_id), :cost] = element_id
        else
            warn("A generator with id $gen_id does not exist. Cost will not be created.")
        end
    end
end

"""
    add_cost_load!(
        net::Network;
        coeffs::Vector{<:Real}=Vector{Float64}(),
        load_id::Union{Missings.Missing,Int}= missing,
        element_id::Int= -1,
    )

Add new load cost to a Network `net`. If `element_id` is not specified, a reasonable
value will be adopted.
"""
function add_cost_load!(
    net::Network;
    coeffs::Vector{<:Real}=Vector{Float64}(),
    load_id::Union{Missings.Missing,Int}= missing,
    element_id::Int= -1,
)
    ids = net.cost_load[:element_id]
    if element_id == -1 || element_id in ids
        control = false
        if element_id in ids && element_id != -1
            w = "Desired bus id, $element_id, is already in use. "
            control = true
        end
        element_id = isempty(ids) ? 1 : maximum(ids) + 1
        if control
            warn(w * "Using id = $element_id instead.")
        end
    end
    if ismissing(load_id)
        push!(net.cost_load, Any[coeffs, element_id])
    else
        load_ids = net.gen[:element_id]
        if load_id in load_ids
            push!(net.cost_load, Any[coeffs, element_id])
            net.ps_load[
                Array{Bool}(net.ps_load[:element_id] .== load_id),
                :cost
            ] = element_id
        else
            warn("A PS load with id $load_id does not exist. Cost will not be created.")
        end
    end
end

"""
    network2pmc(net::Network)

Return a PowerModels network model (dictionary) based on the information contained within
a Network `net`.
"""
function network2pmc(
    net::Network;
    per_unit::Bool=true,
    name::AbstractString="pmc",
    baseMVA::Int=100,
    multinetwork::Bool=false,
    version::Int=2,
)
    outnet = Dict(
        "per_unit" => per_unit, # We may want to check if it is ok to use a deafult here.
        "name" => name,
        "baseMVA" => baseMVA, # We likely don't want a default value here.
        "multinetwork" => multinetwork,
        "version" => version,
        "dcline" => Dict() # We don't use this.
    )
    stripunits!(net)
    gen_dict = Dict()
    for r in eachrow(gen(net))
        old = Dict()
        if string(r[:element_id]) in keys(pmc(net)["gen"])
            old = pmc(net)["gen"][string(r[:element_id])]
        end
        there = !isempty(old)
        coeffs = there ? old["cost"] : [0.0]
        coeffs = !ismissing(r[:cost]) ? cost_gen(net)[:coeffs][r[:cost]] : coeffs
        gen_dict[string(r[:element_id])] = Dict(
            "index" => (!there || !ismissing(r[:element_id])) ? r[:element_id] : old["index"],
            "gen_bus" => (!there || !ismissing(r[:bus])) ? r[:bus] :old["gen_bus"],
            "pg" => (!there || !ismissing(r[:gen_p])) ? r[:gen_p] : old["pg"],
            "pmax" => (!there || !ismissing(r[:p_max])) ? r[:p_max] : old["pmax"],
            "pmin" => (!there || !ismissing(r[:p_min])) ? r[:p_min] : old["pmin"],
            "qg" => (!there || !ismissing(r[:gen_q])) ? r[:gen_q] : old["qg"],
            "qmax" => (!there || !ismissing(r[:q_max])) ? r[:q_max] : old["qmax"],
            "qmin" => (!there || !ismissing(r[:q_min])) ? r[:q_min] : old["qmin"],
            "cost" => coeffs,
            "startup" => (!there || !ismissing(r[:startup_cost])) ? r[:startup_cost] : old["startup"],
            "gen_status" => (!there || !ismissing(r[:status])) ? r[:status] : old["gen_status"],
            "ramp_10" => (!there || !ismissing(r[:ramp])) ? r[:ramp] : old["ramp_10"],
            "qc1max" => 0.0,
            "model" => 2,
            "qc2max" => 0.0,
            "mbase" => baseMVA,
            "pc2" => 0.0,
            "pc1" => 0.0,
            "ramp_q" => 0.0,
            "ramp_30" => 0.0,
            "apf" => 0.0,
            "shutdown" => 0.0,
            "ramp_agc" => 0.0,
            "vg" => 1.01,
            "qc1min" => 0.0,
            "qc2min" => 0.0,
            "ncost" => length(coeffs),
        )
    end
    # Here we also need to add the price sensitive loads as generators
    last_gen = maximum(gen(net)[:element_id])
    for r in eachrow(ps_load(net))
        old = Dict()
        if string(r[:element_id]) in keys(pmc(net)["gen"])
            old = pmc(net)["gen"][string(r[:element_id])]
        end
        there = !isempty(old)
        coeffs = there ? old["cost"] : [0.0]
        coeffs = !ismissing(r[:cost]) ? cost_gen(net)[:coeffs][r[:cost]] : coeffs
        gen_dict[string(r[:element_id] + last_gen)] = Dict(
            "index" => (!there || !ismissing(r[:element_id])) ? r[:element_id] + last_gen : old["index"],
            "gen_bus" => (!there || !ismissing(r[:bus])) ? r[:bus] : old["gen_bus"],
            "pmax" => (!there || !ismissing(r[:load_max])) ? r[:load_max] : old["pmax"],
            "cost" => coeffs,
            "gen_status" => (!there || !ismissing(r[:status])) ? r[:status] : old["gen_status"],
            "ramp_10" => 0.0,
            "startup" => 0.0,
            "qg" => 0.0,
            "qmax" => 0.0,
            "qmin" => 0.0,
            "pmin" => 0.0,
            "qc1max" => 0.0,
            "model" => 2,
            "qc2max" => 0.0,
            "mbase" => baseMVA,
            "pc2" => 0.0,
            "pc1" => 0.0,
            "ramp_q" => 0.0,
            "ramp_30" => 0.0,
            "apf" => 0.0,
            "shutdown" => 0.0,
            "ramp_agc" => 0.0,
            "vg" => 1.01,
            "qc1min" => 0.0,
            "qc2min" => 0.0,
            "ncost" => 1,
        )
    end
    outnet["gen"] = gen_dict
    branch_dict = Dict()
    for r in eachrow(line(net))
        old = Dict()
        if string(r[:element_id]) in keys(pmc(net)["branch"])
            old = pmc(net)["branch"][string(r[:element_id])]
        end
        there = !isempty(old)
        branch_dict[string(r[:element_id])] = Dict(
            "index" => (!there || !ismissing(r[:element_id])) ? r[:element_id] : old["index"],
            "br_r" => (!there || !ismissing(r[:element_id])) ? r[:resistance] : old["br_r"],
            "rate_a" => (!there || !ismissing(r[:element_id])) ? r[:rate_a] : old["rate_a"],
            "rate_b" => (!there || !ismissing(r[:element_id])) ? r[:rate_b] : old["rate_b"],
            "rate_c" => (!there || !ismissing(r[:element_id])) ? r[:rate_c] : old["rate_c"],
            "transformer" => (!there || !ismissing(r[:element_id])) ? r[:transformer] : old["transformer"],
            "f_bus" => (!there || !ismissing(r[:element_id])) ? r[:from_bus] : old["f_bus"],
            "t_bus" => (!there || !ismissing(r[:element_id])) ? r[:to_bus] : old["t_bus"],
            "br_status" => (!there || !ismissing(r[:element_id])) ? r[:status] : old["br_status"],
            "br_x" => (!there || !ismissing(r[:element_id])) ? r[:reactance] : old["br_x"],
            "br_b" => (!there || !ismissing(r[:element_id])) ? r[:susceptance] : old["br_b"],
            "angmin" => (!there || !ismissing(r[:element_id])) ? r[:ang_min] : old["angmin"],
            "angmax" => (!there || !ismissing(r[:element_id])) ? r[:ang_max] : old["andmax"],
            "shift" => 0.0,
            "tap" => 1.0,
        )
    end
    outnet["branch"] = branch_dict
    bus_dict = Dict()
    for r in eachrow(bus(net))
        old = Dict()
        if string(r[:element_id]) in keys(pmc(net)["bus"])
            old = pmc(net)["bus"][string(r[:element_id])]
        end
        there = !isempty(old)
        bus_dict[string(r[:element_id])] = Dict(
            "index" => (!there || !ismissing(r[:element_id])) ? r[:element_id] : old["index"],
            "bus_name" => (!there || !ismissing(r[:element_id])) ? r[:name] : old["bus_name"],
            "vm" => (!there || !ismissing(r[:element_id])) ? r[:voltage] : old["vm"],
            "vmax" => (!there || !ismissing(r[:element_id])) ? r[:volt_max] : old["vmax"],
            "vmin" => (!there || !ismissing(r[:element_id])) ? r[:volt_min] : old["vmin"],
            "bus_type" => (!there || !ismissing(r[:element_id])) ? r[:bus_type] : old["bus_type"],
            "base_kv" => (!there || !ismissing(r[:element_id])) ? r[:base_kv] : old["base_kv"],
            "zone" => 1,
            "bus_i" => (!there || !ismissing(r[:element_id])) ? r[:element_id] : old["bus_i"],
            "qd" => 0.0,
            "gs" => 0.0,
            "bs" => 0.0,
            "area" => 1,
            "va" => 0.0,
            "pd" => 0.0,
        )
    end
    for r in eachrow(pi_load(net))
        if !ismissing(r[:status]) && !ismissing(r[:bus])
            bus_dict[string(r[:bus])]["pd"] += r[:load]
        end
    end
    outnet["bus"] = bus_dict
    return outnet
end

"""
    build_pmc!(net::Network)

Read information contained in `net` and uses it to populate `net.pmc`. This will overwrite
any information previously contained in there.
"""
function build_pmc!(net::Network)
    updated = network2pmc(net)
    for k in keys(updated)
        net.pmc[k] = updated[k]
    end
end

### Getters ###
bus(net::Network) = net.bus
buses(net::Network) = bus(net)
gen(net::Network) = net.gen
gens(net::Network) = gen(net)
generator(net::Network) = gens(net)
generators(net::Network) = generator(net)
pi_load(net::Network) = net.pi_load
ps_load(net::Network) = net.ps_load
load(net::Network) = Dict("pi_load" => pi_load(net), "ps_load" => ps_load(net))
loads(net::Network) = load(net)
line(net::Network) = net.line
lines(net::Network) = line(net)
cost_gen(net::Network) = net.cost_gen
gen_cost(net::Network) = cost_gen(net)
cost_load(net::Network) = net.cost_load
load_cost(net::Network) = cost_load(net)
cost(net::Network) = Dict("cost_gen" => cost_gen(net), "cost_load" => cost_load(net))
costs(net::Network) = cost(net)
pmc(net::Network) = net.pmc
results(net::Network) = net.results

# GenericPowerModels
ACPPowerModel(net::Network) = ACCPowerModel(pmc(net))
APIACPPowerModel(net::Network) = APIACPPowerModel(pmc(net))
DCPPowerModel(net::Network) = DCPPowerModel(pmc(net))
SOCWRPowerModel(net::Network) = SOCWRPowerModel(pmc(net))
QCWRPowerModel(net::Network) = QCWRPowerModel(pmc(net))

# Run OPF
run_dc_opf(net::Network, solver) = run_dc_opf(pmc(net), solver)
run_dc_opf(net::Network) = run_dc_opf(pmc(net))
run_ac_opf(net::Network, solver) = run_ac_opf(pmc(net), solver)
run_ac_opf(net::Network) = run_ac_opf(pmc(net))
run_opf(net::Network, model::DataType, solver) = run_opf(pmc(net), model, solver)
run_opf(net::Network, model::DataType) = run_opf(pmc(net), model)

# Extract results
"""
    lmps(net::Network)

Return a DataFrame with the LMPs for all buses after an OPF run.
"""
function lmps(net::Network)
    isempty(results(net)) && return DataFrame()
    lmps = Float64[]
    buses = Int64[] # Here assuming buses are just numbered. If we are to use general names
    # we should go to either strings or symbols
    for k in keys(results(net)["solution"]["bus"])
        push!(lmps, results(net)["solution"]["bus"][k]["lam_kcl_r"])
        push!(buses, parse(Int64, k))
    end
    # Let's sort it so it looks decent
    p = sortperm(buses)
    buses = buses[p]
    lmps = lmps[p]
    return DataFrame([buses, lmps], [:bus, :lmp])
end

"""
    shadow_prices_lines(net::Network)

Return a DataFrame containing the shadow prices for all lines after an OPF run.
"""
function shadow_prices_lines(net::Network)
    isempty(results(net)) && return DataFrame()
    lower = Float64[]
    upper = Float64[]
    lines = Int64[]
    for k in keys(results(net)["solution"]["branch"])
        push!(lower, results(net)["solution"]["branch"][k]["mu_sm_to"])
        push!(upper, results(net)["solution"]["branch"][k]["mu_sm_fr"])
        push!(lines, parse(Int64, k))
    end
    # Let's sort it so it looks decent
    p = sortperm(lines)
    lines = lines[p]
    lower = lower[p]
    upper = upper[p]
    return DataFrame([lines, lower, upper], [:line, :lower, :upper])
end

"""
    res_gen(net::Network)

Return a DataFrame with the power supplied by each generator as a solution to an OPF.
"""
function res_gen(net::Network)
    isempty(results(net)) && return DataFrame()
    gen_p = Float64[]
    gen_q = Float64[]
    gens = []
    for k in keys(results(net)["solution"]["gen"])
        push!(gen_p, results(net)["solution"]["gen"][k]["pg"])
        push!(gen_q, results(net)["solution"]["gen"][k]["qg"])
        push!(gens, parse(Int64, k))
    end
    return DataFrame([gens, gen_p, gen_q], [:gen, :gen_p, :gen_q])
end

"""
    converged(net::Network)

Return `true` if an OPF was ran and successfully converged, `false` otherwise (inclunding if
no OPF was ran).
"""
function converged(net::Network)
    isempty(results(net)) && return false
    return results(net)["status"] == :LocalInfeasible ? false : true
end

"""
    max_load_percent!(net::Network, maxload::Real)

Scale line ratings such that the maximum load is equal to `maxload`% of the original value.
"""
function max_load_percent!(net::Network, maxload::Real)
    if maxload <= 0
        warn("Maximum load percentage has to be strictly greater than zero.")
    else
        # Let's update both the dataframes and the pmc such that this function can be used
        # at any moment without the risk of changes not getting through.

        maxload /= 100 # % to fraction

        # First the dataframes:
        line(net)[:rate_a] *= maxload
        line(net)[:rate_b] *= maxload
        line(net)[:rate_c] *= maxload

        # Now the pmc:
        for k in keys(pmc(net)["branch"])
            pmc(net)["branch"][k]["rate_a"] *= maxload
            pmc(net)["branch"][k]["rate_b"] *= maxload
            pmc(net)["branch"][k]["rate_c"] *= maxload
        end
    end
end

"""
    max_load_percent!(pmc::Dict, maxload::Real)

Scale line ratings such that the maximum load is equal to `maxload`% of the original value.
"""
function max_load_percent!(pmc::Dict, maxload::Real)
    if maxload <= 0
        warn("Maximum load percentage has to be strictly greater than zero.")
    else
        maxload /= 100 # % to fraction
        for k in keys(pmc["branch"])
            pmc["branch"][k]["rate_a"] *= maxload
            pmc["branch"][k]["rate_b"] *= maxload
            pmc["branch"][k]["rate_c"] *= maxload
        end
    end
end

end # module end