using ClimaOcean
using ClimaOcean.ECCO: ECCO4Monthly, NearestNeighborInpainting
using OrthogonalSphericalShellGrids
using Oceananigans
using Oceananigans.Units
using CFTime
using Dates
using Printf
using CUDA: @allowscalar, device!

using Oceananigans.Grids: znode
