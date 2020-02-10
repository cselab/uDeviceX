#include "membrane_vector.h"
#include <mirheo/core/mirheo_undump.h>
#include <mirheo/core/utils/config.h>

namespace mirheo
{

MembraneVector::MembraneVector(const MirState *state, const std::string& name, real mass, std::shared_ptr<MembraneMesh> mptr, int nObjects) :
    ObjectVector( state, name, mass, mptr->getNvertices(),
                  std::make_unique<LocalObjectVector>(this, mptr->getNvertices(), nObjects),
                  std::make_unique<LocalObjectVector>(this, mptr->getNvertices(), 0) )
{
    mesh = std::move(mptr);
}

MembraneVector::MembraneVector(const MirState *state, Undumper& un, const ConfigObject& config) :
    MembraneVector{state, config["name"], config["mass"],
                   un.getContext().getShared<MembraneMesh>(config["mesh"]), 0}
{
    assert(config["__type"] == "MembraneVector");

    int expectedSize = config["objSize"];
    int importedSize = this->mesh->getNvertices();
    if (expectedSize != importedSize) {
        die("Mesh \"%s\" has %d vertices instead of expected %d.",
            config["mesh"].getString().c_str(), importedSize, expectedSize);
    }
}

MembraneVector::~MembraneVector() = default;

void MembraneVector::saveSnapshotAndRegister(Dumper& dumper)
{
    // MembraneVector does not modify _saveSnapshot.
    dumper.registerObject<MembraneVector>(
            this, ObjectVector::_saveSnapshot(dumper, "MembraneVector"));
}

} // namespace mirheo
