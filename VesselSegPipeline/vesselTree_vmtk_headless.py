# type: ignore
import os
import sys
import argparse
import slicer
import vtk

# --- Add SlicerVMTK scripted module path ---
vmtk_path = "/Applications/Slicer.app/Contents/Extensions-33241/SlicerVMTK/lib/Slicer-5.8/qt-scripted-modules"
if vmtk_path not in sys.path:
    sys.path.append(vmtk_path)

from VesselnessFiltering import VesselnessFilteringLogic


def run_vesselness(input_path, output_dir, sigma_min=0.5, sigma_max=3.0):
    """
    Runs Vesselness Filtering via the SlicerVMTK VesselnessFilteringLogic.
    """
    print(f"[vmtk-direct] Input: {input_path}")
    print(f"[vmtk-direct] Output dir: {output_dir}")
    print(f"[vmtk-direct] Sigma range: {sigma_min}-{sigma_max}")

    # Load input CTA
    volumeNode = slicer.util.loadVolume(input_path)
    if not volumeNode:
        raise RuntimeError(f"Failed to load {input_path}")

    # Prepare output node
    vesselNode = slicer.mrmlScene.AddNewNodeByClass("vtkMRMLScalarVolumeNode", "VesselnessOutput")

    # Run vesselness filter using the internal VMTK logic
    logic = VesselnessFilteringLogic()

    # Typical parameter set (feel free to tune)
    alpha = 0.3  # suppress plates
    beta = 0.3   # suppress blobs
    contrast = 150
    print("[vmtk-direct] Running VesselnessFilteringLogic.computeVesselnessVolume() ...")

    logic.computeVesselnessVolume(
        currentVolumeNode=volumeNode,
        currentOutputVolumeNode=vesselNode,
        minimumDiameterMm=sigma_min,
        maximumDiameterMm=sigma_max,
        alpha=alpha,
        beta=beta,
        contrastMeasure=contrast
    )

    print("[vmtk-direct] Vesselness filtering completed.")

    # Save the vesselness volume
    os.makedirs(output_dir, exist_ok=True)
    vessel_path = os.path.join(output_dir, "vesselness.nrrd")
    slicer.util.saveNode(vesselNode, vessel_path)

    # Convert to segmentation & export STL (optional)
    segNode = slicer.mrmlScene.AddNewNodeByClass("vtkMRMLSegmentationNode", "VesselSeg")
    segNode.CreateDefaultDisplayNodes()
    slicer.modules.segmentations.logic().ImportLabelmapToSegmentationNode(vesselNode, segNode)

    mesh_dir = os.path.join(output_dir, "mesh")
    os.makedirs(mesh_dir, exist_ok=True)
    slicer.modules.segmentations.logic().ExportSegmentsClosedSurfaceRepresentationToFiles(
        mesh_dir, segNode, None, "STL", True, 1.0, False
    )

    print(f"[vmtk-direct] Saved: {vessel_path}")
    print(f"[vmtk-direct] STL mesh written to: {mesh_dir}")

    slicer.mrmlScene.Clear(0)  # Clean scene for next case


def main():
    parser = argparse.ArgumentParser(description="Run Vesselness Filtering via SlicerVMTK logic")
    parser.add_argument("--input", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--sigma-min", type=float, default=0.5)
    parser.add_argument("--sigma-max", type=float, default=3.0)
    args = parser.parse_args()

    run_vesselness(args.input, args.output_dir, args.sigma_min, args.sigma_max)


if __name__ == "__main__":
    main()