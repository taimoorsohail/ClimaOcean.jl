using ClimaOcean
using ClimaOcean.ECCO: ECCO4Monthly
using ClimaSeaIce
using OrthogonalSphericalShellGrids
using Oceananigans
using Oceananigans.Units
using CFTime
using Dates
using Printf
using Statistics
using Oceananigans.TimeSteppers: update_state!

arch = CPU()

#=
Nx = 360 * 4
Ny = 60 * 4
Nz = 60
=#

Nx = 120
Ny = 60
Nz = 30
z_faces = exponential_z_faces(; Nz, depth=5000, h=30)

latitude = (-80, -20)
longitude = (0, 360)

underlying_grid = LatitudeLongitudeGrid(arch; size=(Nx, Ny, Nz), halo=(7, 7, 7), latitude, longitude, z=z_faces)
bottom_height = regrid_bathymetry(underlying_grid)
grid = ImmersedBoundaryGrid(underlying_grid, GridFittedBottom(bottom_height))

gm = Oceananigans.TurbulenceClosures.IsopycnalSkewSymmetricDiffusivity(κ_skew=2000, κ_symmetric=2000)
catke = ClimaOcean.OceanSimulations.default_ocean_closure()
viscous_closure = Oceananigans.TurbulenceClosures.HorizontalScalarDiffusivity(ν=2000)

dates = DateTimeProlepticGregorian(1993, 1, 1) : Month(1) : DateTimeProlepticGregorian(1993, 12, 1)
temperature = ECCOMetadata(:temperature, dates, ECCO4Monthly())
salinity = ECCOMetadata(:salinity, dates, ECCO4Monthly())

restoring_rate = 1/2days
mask = LinearlyTaperedPolarMask(northern=(-25, -20))
FT = ECCORestoring(temperature, grid; mask, rate=restoring_rate)
FS = ECCORestoring(salinity, grid; mask, rate=restoring_rate)

ocean = ocean_simulation(grid;
                         #momentum_advection =  VectorInvariant(),
                         #tracer_advection = Centered(order=2),
                         #closure = (gm, catke, viscous_closure),
                         closure = catke,
                         # forcing = (T=FT, S=FT),
                         tracers = (:T, :S, :e))

start_date = first(dates)
#set!(ocean.model, T=ECCOMetadata(:temperature; dates=start_date),
#                  S=ECCOMetadata(:salinity; dates=start_date))

radiation  = Radiation(arch)
atmosphere = JRA55PrescribedAtmosphere(arch; backend=JRA55NetCDFBackend(20))
# ocean.model.clock.time = 180days

#####
##### Sea ice model stuff
#####

sea_ice_grid = LatitudeLongitudeGrid(arch; size=(Nx, Ny), latitude, longitude, topology=(Periodic, Bounded, Flat))
land_mask = interior(bottom_height) .>= 0
sea_ice_grid = ImmersedBoundaryGrid(underlying_grid, GridFittedBoundary(land_mask))
top_sea_ice_temperature = Field{Center, Center, Nothing}(sea_ice_grid)
top_heat_boundary_condition = PrescribedTemperature(top_sea_ice_temperature)
ice_thermodynamics = SlabSeaIceThermodynamics(sea_ice_grid; top_heat_boundary_condition)
                                              
top_sea_ice_heat_flux = Field{Center, Center, Nothing}(sea_ice_grid)
bottom_sea_ice_heat_flux = Field{Center, Center, Nothing}(sea_ice_grid)

sea_ice_model = SeaIceModel(sea_ice_grid;
                            top_heat_flux = top_sea_ice_heat_flux,
                            bottom_heat_flux = bottom_sea_ice_heat_flux,
                            ice_thermodynamics)

sea_ice = Simulation(sea_ice_model, Δt=10minutes)

thickness_meta = ECCOMetadata(:sea_ice_thickness; dates=start_date)
concentration_meta = ECCOMetadata(:sea_ice_concentration; dates=start_date)
set!(sea_ice.model.ice_thickness, thickness_meta)
set!(sea_ice.model.ice_concentration, concentration_meta)

set!(ocean.model, T=ECCOMetadata(:temperature; dates=start_date),
                  S=ECCOMetadata(:salinity; dates=start_date), u=0, v=0)

coupled_model = OceanSeaIceModel(ocean, sea_ice; atmosphere, radiation) 
simulation = Simulation(coupled_model; Δt=10minutes, stop_time=3days)

ℵ = sea_ice.model.ice_concentration
heatmap(ℵ)

#h = sea_ice.model.ice_thickness
#heatmap(h)


#=

wall_time = Ref(time_ns())

function progress(sim)
    sea_ice = sim.model.sea_ice
    h = sea_ice.model.ice_thickness
    Tai = coupled_model.interfaces.atmosphere_sea_ice_interface.temperature
    hmax = maximum(interior(h))
    #Taiavg = mean(interior(Tai))
    Taimin = minimum(interior(Tai))

    ocean = sim.model.ocean
    u, v, w = ocean.model.velocities
    T = ocean.model.tracers.T
    Tmax = maximum(interior(T))
    Tmin = minimum(interior(T))
    umax = (maximum(abs, interior(u)), maximum(abs, interior(v)), maximum(abs, interior(w)))
    step_time = 1e-9 * (time_ns() - wall_time[])

    Fv_ao = coupled_model.interfaces.atmosphere_ocean_interface.fluxes.water_vapor
    Qv_ao = coupled_model.interfaces.atmosphere_ocean_interface.fluxes.latent_heat
    Qc_ao = coupled_model.interfaces.atmosphere_ocean_interface.fluxes.sensible_heat
    τx_ao = coupled_model.interfaces.atmosphere_ocean_interface.fluxes.x_momentum
    τy_ao = coupled_model.interfaces.atmosphere_ocean_interface.fluxes.y_momentum

    Fv_ai = coupled_model.interfaces.atmosphere_sea_ice_interface.fluxes.water_vapor
    Qv_ai = coupled_model.interfaces.atmosphere_sea_ice_interface.fluxes.latent_heat
    Qc_ai = coupled_model.interfaces.atmosphere_sea_ice_interface.fluxes.sensible_heat
    τx_ai = coupled_model.interfaces.atmosphere_sea_ice_interface.fluxes.x_momentum
    τy_ai = coupled_model.interfaces.atmosphere_sea_ice_interface.fluxes.y_momentum

    msg = @sprintf("Time: %s, n: %d, Δt: %s, \
                   max(h): %.1f, \
                   min(Ti): %.2f ᵒC, \
                   max|u|: (%.2e, %.2e, %.2e) m s⁻¹, \
                   extrema(To): (%.1f, %.1f) ᵒC, \
                   wall time: %s \n",
                   prettytime(sim), iteration(sim), prettytime(sim.Δt),
                   hmax,
                   Taimin,# Taiavg,
                   umax...,
                   Tmin, Tmax,
                   prettytime(step_time))

    max_Fv_ai = maximum(Fv_ai)
    max_Qv_ai = maximum(Qv_ai)
    max_Qc_ai = maximum(Qc_ai)
    max_τx_ai = maximum(τx_ai)
    max_τy_ai = maximum(τy_ai)

    min_Fv_ai = minimum(Fv_ai)
    min_Qv_ai = minimum(Qv_ai)
    min_Qc_ai = minimum(Qc_ai)
    min_τx_ai = minimum(τx_ai)
    min_τy_ai = minimum(τy_ai)

    max_Fv_ao = maximum(Fv_ao)
    max_Qv_ao = maximum(Qv_ao)
    max_Qc_ao = maximum(Qc_ao)
    max_τx_ao = maximum(τx_ao)
    max_τy_ao = maximum(τy_ao)

    min_Fv_ao = minimum(Fv_ao)
    min_Qv_ao = minimum(Qv_ao)
    min_Qc_ao = minimum(Qc_ao)
    min_τx_ao = minimum(τx_ao)
    min_τy_ao = minimum(τy_ao)

    msg *= @sprintf("    ao: extrema(Qv): (% 6d, % 6d), ao: extrema(Qc): (% 6d, % 6d), ao: extrema(Fv): (% 6d, % 6d), ao: extrema(τx): (% 6d, % 6d), ao: extrema(τy): (% 6d, % 6d) \n",
                    min_Qv_ao, max_Qv_ao,
                    min_Qc_ao, max_Qc_ao,
                    1e6 * min_Fv_ao, 1e6 * max_Fv_ao,
                    1e3 * min_τx_ao, 1e3 * max_τx_ao,
                    1e3 * min_τy_ao, 1e3 * max_τy_ao)

    msg *= @sprintf("    ai: extrema(Qv): (% 6d, % 6d), ai: extrema(Qc): (% 6d, % 6d), ai: extrema(Fv): (% 6d, % 6d)",
                    min_Qv_ai, max_Qv_ai,
                    min_Qc_ai, max_Qc_ai,
                    1e6 * min_Fv_ai, 1e6 * max_Fv_ai)

    @info msg
    
    wall_time[] = time_ns()

    return nothing
end

add_callback!(simulation, progress, IterationInterval(100))

Ql = coupled_model.interfaces.atmosphere_ocean_interface.fluxes.latent_heat
Qs = coupled_model.interfaces.atmosphere_ocean_interface.fluxes.sensible_heat
τx = coupled_model.interfaces.atmosphere_ocean_interface.fluxes.x_momentum
τy = coupled_model.interfaces.atmosphere_ocean_interface.fluxes.y_momentum
Fv = coupled_model.interfaces.atmosphere_ocean_interface.fluxes.water_vapor
fluxes = (; Ql, Qs, τx, τy, Fv)
ocean_outputs = merge(ocean.model.velocities, ocean.model.tracers)

Nz = size(grid, 3)
ocean_outputs = NamedTuple(name => view(ocean_outputs[name], :, :, Nz)
                           for name in keys(ocean_outputs))

h = sea_ice_model.ice_thickness
ℵ = sea_ice_model.ice_concentration
Ti = top_sea_ice_temperature
sea_ice_outputs = (; h, ℵ, Ti)

outputs = merge(ocean_outputs, sea_ice_outputs, fluxes)

ow = JLD2OutputWriter(ocean.model, outputs,
                      filename = "three_degree_simulation_surface.jld2",
                      indices = (:, :, size(grid, 3)),
                      schedule = TimeInterval(1days),
                      overwrite_existing = true)

simulation.output_writers[:jld2] = ow

#run!(simulation)
=#
