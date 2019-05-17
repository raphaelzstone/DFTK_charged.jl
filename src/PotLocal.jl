
# TODO add function to add two potentials, which have the same basis?

"""
Class for holding the values of a local potential,
like the local part of a pseudopotential
"""
struct PotLocal
    basis::PlaneWaveBasis
    values_Yst  # Values on the Yst grid

    function PotLocal(basis::PlaneWaveBasis, values_Yst::AbstractArray)
        if size(basis.grid_Yst) != size(values_Yst)
            error("Size mismatch between real-space potential grid Y* as defined " *
                  "by the plane-wave basis (== $(size(basis.grid_Yst))) and the " *
                  "size of the passed values (== $(size(values_Yst))).")
        end
        new(basis, values_Yst)
    end
end

apply_real!(tmp_Yst, pot::PotLocal, in_Yst) = tmp_Yst .= pot.values_Yst .* in_Yst

"""
Function which generates a local potential.

The potential is generated in Fourier space as a sum of analytic terms
and then transformed onto the real-space potential grid Y*. For this
positions of all "species" involved in the lattice may be given
via a mapping from an identifier to a list of positions (in cartesian
or fractional coordinates) in the unit cell. The unit cell definition
is drawn from the lattice vectors stored inside the PlaneWaveBasis object.

# Arguments
- `basis`: `PlaneWaveBasis` object containing the lattice, the wave vectors
            and the potential grid.
- `positions`: Something which can be converted to a `Dict{Any, Vector{Vector}}`.
               Provides the list of positions for each of the species.
               Typically one wants to use a list of `Pair` objects, see
               the example below.
- `generators`: Mapping from the species identifier to the function used
                to provide the values of the potential in the Fourier basis.
                The function will be queried for each wave vector G.
                For each species a separate mapping entry has to be present.
                See specialised methods below for more user-friendly alternatives.
- `parameters`: Optional parameters for each species, which will be appended
                to the call to the `generator` for this particular species.
- `coords_are_cartesian`: By default it is assumed that the `positions` mapping
                maps to fractional coordinats for the species. This signals
                that the provided coordinates are cartesian coordinates instead.
- `compensating_background`: Should the DC component be skipped, i.e. should
                an implicit compensating change background be included in the
                potential model. The default is yes.

# Example
If the lattice is composed of atoms, the identfiers would typically be
the chemical symbol as a string. The positions are just the atomic
positions on the lattice. A typical generator is
`(G, Z) -> -Z / sum(abs2, G)`, i.e. the Coulomb-potential parametrised
in the nuclear charge. As parameters the charge `Z` for each atom
needs to be specified. For sodium chloride, this would result in
```julia-repl
julia> PotLocal(basis,
                ["Na" => [[0,0,0], [1/2, 1/2, 0], [1/2, 0, 1/2], [0, 1/2, 1/2]],
                 "Cl" => [[0 1/2 0], [1/2 0 0], [0 0 1/2], [1/2, 1/2, 1/2]]]
                ["Na" => (G, Z) -> -Z / sum(abs2, G),
                 "Cl" => (G, Z) -> -Z / sum(abs2, G)],
                ["Na" => 11, "Cl" => 17])
```
"""
function PotLocal(pw::PlaneWaveBasis, positions, generators; parameters = (),
                  coords_are_cartesian=false, compensating_background=true)
    T = eltype(pw)
    positions = Dict{Any, Vector{Vector{T}}}(positions)
    generators = Dict{Any, Function}(generators)
    parameters = Dict(parameters)

    # The list of all species
    species = keys(positions)

    for spec in species
        if !haskey(generators, spec)
            raise(ArgumentError("No generator found for species $(string(spec))." *
                                "Please check that the generator specification contains" *
                                " a key for each species defined in the positions " *
                                "parameter."))
        end
    end

    # Convert positions to cartesian coordinates if they are not yet
    if !coords_are_cartesian
        for posvecs in values(positions)
            for vec in posvecs
                vec[:] = pw.lattice * vec
            end
        end
    end

    # Closure to get the potential value a particular wave vector G
    function call_generators(G)
        # Bind the parameters to the generators: Given a G wave vector
        # and a species, return the potential value
        potential(G, spec) = generators[spec](G, get(parameters, spec, ())...)

        # Sum the values over all species and positions of the species,
        # taking into account the structure factor
        sum(
            4π / pw.unit_cell_volume  # Prefactor spherical Hankel transform
            * potential(G, spec)      # Potential data for wave vector G
            * cis(dot(G, R))          # Structure factor
            for spec in species
            for R in positions[spec]
        )
    end

    # Get the values in the plane-wave basis set Y
    values_Y = call_generators.(pw.Gs)

    # Zero DC component if compensating background is requested
    if compensating_background
        values_Y[pw.idx_DC] = 0
    end

    values_Yst = similar(pw.grid_Yst, Complex{T})
    Y_to_Yst!(pw, values_Y, values_Yst)

    if maximum(imag(values_Yst)) > 100 * eps(T)
        raise(ArgumentError("Expected potential on the real-space grid Y* to be entirely" *
                            " real-valued, but the present potential gives rise to a " *
                            "maximal imaginary entry of $(maximum(imag(values_Yst)))."))
    end
    PotLocal(pw, real(values_Yst))
end


"""
Specialisation of above function using only a single generator function,
which is applied for all species.

# Example
```julia-repl
julia> PotLocal(basis,
                ["Na" => [[0,0,0], [1/2, 1/2, 0], [1/2, 0, 1/2], [0, 1/2, 1/2]],
                 "Cl" => [[0 1/2 0], [1/2 0 0], [0 0 1/2], [1/2, 1/2, 1/2]]],
                (G, Z) -> -Z / sum(abs2, G),
                ["Na" => 11, "Cl" => 17])
```
"""
function PotLocal(basis::PlaneWaveBasis, positions, generator::Function; parameters = (),
                  coords_are_cartesian=false, compensating_background=true)
    positions = Dict(positions)
    generators = Dict(k => generator for k in keys(positions))
    PotLocal(basis, positions, generators, parameters=parameters,
             coords_are_cartesian=coords_are_cartesian,
             compensating_background=compensating_background)
end

"""
Specialisation of above function for cases with only a single species

# Example
```julia-repl
julia> PotLocal(basis, [[0,0,0], [1/8, 1/8, 1/8]], G -> -12 / sum(abs2, G))
```
"""
function PotLocal(basis::PlaneWaveBasis, positions::Vector{Vector{T}},
                  generator::Function; coords_are_cartesian=false,
                  compensating_background=true) where T <: Number
    positions = Dict(:species => positions)
    generators = Dict(:species => generator)
    PotLocal(basis, positions, generators, coords_are_cartesian=coords_are_cartesian,
             compensating_background=compensating_background)
end


function PotLocal(basis::PlaneWaveBasis, positions::Vector{T},
                  generator::Function; coords_are_cartesian=false,
                  compensating_background=true) where T <: Number
    PotLocal(basis, [positions], generator, coords_are_cartesian=coords_are_cartesian,
             compensating_background=compensating_background)
end
