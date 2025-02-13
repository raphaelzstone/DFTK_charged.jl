"""
NbandsAlgorithm subtypes determine how many bands to compute and converge
in each SCF step.
"""
abstract type NbandsAlgorithm end

function default_n_bands(model, temperature_factor=1.05)
    n_spin = model.n_spin_components
    min_n_bands = div(model.n_electrons, n_spin * filled_occupation(model), RoundUp)
    factor = iszero(model.temperature) ? 1.0 : temperature_factor
    ceil(Int, min_n_bands * factor)
end
default_occupation_threshold(T = Float64) = max(T(1e-6), 100eps(T))


"""
In each SCF step converge exactly `n_bands_converge`, computing along the way exactly
`n_bands_compute` (usually a few more to ease convergence in systems with small gaps).
"""
@kwdef struct FixedBands <: NbandsAlgorithm
    n_bands_converge::Int # Number of bands to converge
    n_bands_compute::Int = n_bands_converge + 3 # bands to compute (not always converged)
    # Threshold for orbital to be counted as occupied
    occupation_threshold::Float64 = default_occupation_threshold(Float64)
end
function FixedBands(model::Model{T}; temperature_factor_converge=1.20) where {T}
    n_bands_converge = default_n_bands(model, temperature_factor_converge)
    FixedBands(; n_bands_converge, n_bands_compute=n_bands_converge + 3,
               occupation_threshold=default_occupation_threshold(T))
end
function determine_n_bands(bands::FixedBands, occupation, eigenvalues, ψ)
    (; bands.n_bands_converge, bands.n_bands_compute)
end


"""
Dynamically adapt number of bands to be converged to ensure that the orbitals of lowest
occupation are occupied to at most `occupation_threshold`. To obtain rapid convergence
of the eigensolver a gap between the eigenvalues of the last occupied orbital and the last
computed (but not converged) orbital of `gap_min` is ensured.

# Examples
For difficult cases with bad SCF convergence it can be helpful to *increase*
`temperature_factor_converge` or `n_bands_converge`
slightly to ensure that more bands are fully converged.
For example:
```julia
nbandsalg = AdaptiveBands(model; temperature_factor_converge=1.1)
self_consistent_field(basis; nbandsalg, kwargs...)
```
"""
@kwdef struct AdaptiveBands <: NbandsAlgorithm
    n_bands_converge::Int  # Minimal number of bands to converge
    n_bands_compute::Int   # Minimal number of bands to compute
    occupation_threshold::Float64 = default_occupation_threshold(Float64)
    gap_min::Float64 = 1e-2   # Minimal gap between converged and computed bands
end
function AdaptiveBands(model::Model{T};
                       temperature_factor_converge=1.05,
                       temperature_factor_compute=1.20,
                       n_bands_converge=default_n_bands(model, temperature_factor_converge),
                       occupation_threshold=default_occupation_threshold(T),
                       kwargs...) where {T}
    n_bands_compute = max(3 + n_bands_converge,
                          default_n_bands(model, temperature_factor_compute))
    AdaptiveBands(; n_bands_converge, n_bands_compute, occupation_threshold, kwargs...)
end

function determine_n_bands(bands::AdaptiveBands, occupation::Nothing, eigenvalues, ψ)
    if isnothing(ψ)
        n_bands_compute = bands.n_bands_compute
    else
        n_bands_compute = max(bands.n_bands_compute, maximum(ψk -> size(ψk, 2), ψ))
    end
    # Boost number of bands to converge temporarily for the next SCF step to have more
    # information around after the next step and to thus make a better decision
    # on the number of bands we actually care about. Note that this is temporary, since
    # not stored inside n_bands_converge.
    n_bands_converge = floor(Int, (bands.n_bands_converge + bands.n_bands_compute) / 2)
    @debug "determine_n_bands" n_bands_converge n_bands_compute
    (; n_bands_converge, n_bands_compute)
end
function determine_n_bands(bands::AdaptiveBands, occupation::AbstractVector,
                           eigenvalues::AbstractVector, ψ::AbstractVector)
    # Determine number of bands to be actually converged
    # Bring occupation on the CPU, or findlast will fail
    occupation = [to_cpu(occk) for occk in occupation]
    n_bands_occ = maximum(occupation) do occk
        something(findlast(fnk -> abs(fnk) ≥ bands.occupation_threshold, occk),
                  length(occk) + 1)
    end
    n_bands_converge = max(bands.n_bands_converge, n_bands_occ)

    # Determine number of bands to be computed
    n_bands_compute_ε = maximum(eigenvalues) do εk
        n_bands_converge > length(εk) && return length(εk) + 1
        something(findlast(εnk -> εnk ≤ εk[n_bands_converge] + bands.gap_min, εk),
                  length(εk) + 1)
    end
    n_bands_compute = max(bands.n_bands_compute, n_bands_compute_ε, n_bands_converge + 3)
    if !isnothing(ψ)
        n_bands_compute = max(n_bands_compute, maximum(ψk -> size(ψk, 2), ψ))
    end
    @debug "determine_n_bands" n_bands_converge n_bands_compute n_bands_occ n_bands_compute_ε
    (; n_bands_converge, n_bands_compute)
end

