#type: ignore
import logging
import os
from typing import Annotated, Optional

import vtk
import SimpleITK as sitk
import sitkUtils
import qt
import numpy as np

import slicer
from slicer.i18n import tr as _
from slicer.i18n import translate
from slicer.ScriptedLoadableModule import *
from slicer.util import VTKObservationMixin
from slicer.parameterNodeWrapper import (
    parameterNodeWrapper,
    WithinRange,
)

from slicer import vtkMRMLScalarVolumeNode
from slicer import vtkMRMLLabelMapVolumeNode
from slicer import vtkMRMLSegmentationNode


# ================================
# VesselTreeGenerator
# ================================


class VesselTreeGenerator(ScriptedLoadableModule):
    """Uses ScriptedLoadableModule base class, available at:
    https://github.com/Slicer/Slicer/blob/main/Base/Python/slicer/ScriptedLoadableModule.py
    """

    def __init__(self, parent):
        ScriptedLoadableModule.__init__(self, parent)
        self.parent.title = _("VesselTreeGenerator")  # TODO: make this more human readable by adding spaces
        # TODO: set categories (folders where the module shows up in the module selector)
        self.parent.categories = [translate("qSlicerAbstractCoreModule", "SEEG Planner OUH")]
        self.parent.dependencies = []  # TODO: add here list of module names that this module requires
        self.parent.contributors = ["Jonas Ludwig (KIT)"]  
        # TODO: update with short description of the module and a link to online module documentation
        # _() function marks text as translatable to other languages
        self.parent.helpText = _(""" The Vessel Tree Generator module provides an automated workflow for extracting vascular
structures from volumetric brain images. It applies optional noise reduction using median
filtering, enhances vessel contrast through a sigmoid intensity transformation, and allows
interactive threshold-based segmentation with real-time preview. The resulting segmentation
can be refined by keeping only the largest connected vessel island and automatically
converted into a 3D surface model for visualization. All steps are integrated into a
streamlined interface requiring minimal user interaction.""")
        # TODO: replace with organization, grant and thanks
        self.parent.acknowledgementText = _(""" """)

        # Additional initialization step after application startup is complete
        slicer.app.connect("startupCompleted()", registerSampleData)


# ================================
# Register sample data sets in Sample Data module
# ================================


def registerSampleData():
    """Add data sets to Sample Data module."""
    # It is always recommended to provide sample data for users to make it easy to try the module,
    # but if no sample data is available then this method (and associated startupCompeted signal connection) can be removed.

    import SampleData

    iconsPath = os.path.join(os.path.dirname(__file__), "Resources/Icons")

    # To ensure that the source code repository remains small (can be downloaded and installed quickly)
    # it is recommended to store data sets that are larger than a few MB in a Github release.

    # VesselTreeGenerator1
    SampleData.SampleDataLogic.registerCustomSampleDataSource(
        # Category and sample name displayed in Sample Data module
        category="VesselTreeGenerator",
        sampleName="VesselTreeGenerator1",
        # Thumbnail should have size of approximately 260x280 pixels and stored in Resources/Icons folder.
        # It can be created by Screen Capture module, "Capture all views" option enabled, "Number of images" set to "Single".
        thumbnailFileName=os.path.join(iconsPath, "VesselTreeGenerator1.png"),
        # Download URL and target file name
        uris="https://github.com/Slicer/SlicerTestingData/releases/download/SHA256/998cb522173839c78657f4bc0ea907cea09fd04e44601f17c82ea27927937b95",
        fileNames="VesselTreeGenerator1.nrrd",
        # Checksum to ensure file integrity. Can be computed by this command:
        #  import hashlib; print(hashlib.sha256(open(filename, "rb").read()).hexdigest())
        checksums="SHA256:998cb522173839c78657f4bc0ea907cea09fd04e44601f17c82ea27927937b95",
        # This node name will be used when the data set is loaded
        nodeNames="VesselTreeGenerator1",
    )


# ================================
# VesselTreeGeneratorParameterNode
# ================================


@parameterNodeWrapper
class VesselTreeGeneratorParameterNode:
    """
    The parameters needed by module.
    
    inputVolume — The volume selected by the user as processing input.
    outputVolume — The volume where the processed (median + sigmoid) result is written.
    alphaValue — Alpha parameter of the sigmoid filter, controlling steepness.
    betaValue — Beta parameter of the sigmoid filter, controlling the center point.
    saveIntermediateVolume — If enabled, the module stores the median-filtered volume as an additional node (“intermediate_median”) before sigmoid is applied.
    imageThreshold — Threshold value used for segmentation preview or processing steps requiring a scalar cutoff.
    """
    
    inputVolume: vtkMRMLScalarVolumeNode
    outputVolume: vtkMRMLScalarVolumeNode
    sourceSegmentationVolume: vtkMRMLSegmentationNode
    alphaValue: Annotated[float, WithinRange(0,150)] = 60
    betaValue: Annotated[float, WithinRange(0,500)] = 200
    saveIntermediateVolume: bool = False
    imageThreshold: Annotated[float, WithinRange(-100, 500)] = 100


# ================================
# VesselTreeGeneratorWidget
# ================================


class VesselTreeGeneratorWidget(ScriptedLoadableModuleWidget, VTKObservationMixin):
    """Uses ScriptedLoadableModuleWidget base class, available at:
    https://github.com/Slicer/Slicer/blob/main/Base/Python/slicer/ScriptedLoadableModule.py
    """

    def __init__(self, parent=None) -> None:
        """Called when the user opens the module the first time and the widget is initialized."""
        ScriptedLoadableModuleWidget.__init__(self, parent)
        VTKObservationMixin.__init__(self)  # needed for parameter node observation
        self.logic = None
        self._parameterNode = None
        self._parameterNodeGuiTag = None
        
        # For Noise reduction 
        self._medianRadius = None
    
        # Internal Segment Editor widget for thresholding and Largest Islands
        self.segmentEditorWidget3D = None
        self.segmentEditorNode3D = None
    
        # For 3D model generation
        self._segmentationNode3D = None
        self._segmentId3D = None
        
        # threshold slider (qMRMLVolumeThresholdWidget) 
        self._lastThresholdMin = None
        self._lastThresholdMax = None   
               
    def setup(self) -> None:
        """Called when the user opens the module the first time and the widget is initialized."""
        ScriptedLoadableModuleWidget.setup(self)

        # Load widget from .ui file (created by Qt Designer).
        # Additional widgets can be instantiated manually and added to self.layout.
        uiWidget = slicer.util.loadUI(self.resourcePath("UI/VesselTreeGenerator.ui"))
        self.layout.addWidget(uiWidget)
        self.ui = slicer.util.childWidgetVariables(uiWidget)

        # Set scene in MRML widgets. Make sure that in Qt designer the top-level qMRMLWidget's
        # "mrmlSceneChanged(vtkMRMLScene*)" signal in is connected to each MRML widget's.
        # "setMRMLScene(vtkMRMLScene*)" slot.
        uiWidget.setMRMLScene(slicer.mrmlScene)
        
        
        # Invisible Segment Editor Widget
        self.segmentEditorWidget3D = slicer.qMRMLSegmentEditorWidget()
        self.segmentEditorWidget3D.setMRMLScene(slicer.mrmlScene)
        self.segmentEditorNode3D = slicer.mrmlScene.AddNewNodeByClass("vtkMRMLSegmentEditorNode")
        self.segmentEditorWidget3D.setMRMLSegmentEditorNode(self.segmentEditorNode3D)
        
        # Create logic class. Logic implements all computations that should be possible to run
        # in batch mode, without a graphical user interface.
        self.logic = VesselTreeGeneratorLogic()

        # Connections

        # These connections ensure that we update parameter node when scene is closed
        self.addObserver(slicer.mrmlScene, slicer.mrmlScene.StartCloseEvent, self.onSceneStartClose)
        self.addObserver(slicer.mrmlScene, slicer.mrmlScene.EndCloseEvent, self.onSceneEndClose)

        # Buttons
        self.ui.buttonLow.connect("toggled(bool)", self.onNoiseReductionLow)
        self.ui.buttonHigh.connect("toggled(bool)", self.onNoiseReductionHigh)
        self.ui.applyButton.connect("clicked(bool)", self.onApplySettings)
        self.ui.pushButtonSegementation.connect("clicked(bool)", self.onAddSegmentation)
        self.ui.pushButtonThresholdShow3D.connect("clicked(bool)", self.onApplyThresholdShow3D)
        self.ui.pushButtonLMapMaurer.connect("clicked(bool)", self.onComputeMaurerDistance)
        
        # Sliders (Sigmoid)
        self.ui.rangeWidgetThreshold.connect("valuesChanged(double,double)", self.onThresholdValuesChanged)
        
        # Make sure parameter node is initialized (needed for module reload)
        self.initializeParameterNode()   

    def cleanup(self) -> None:
        """Called when the application closes and the module widget is destroyed."""
        self.removeObservers()
        
    def enter(self) -> None:
        """Called each time the user opens this module."""
        # Make sure parameter node exists and observed
        self.initializeParameterNode()
    
    def exit(self) -> None:
        """Called each time the user opens a different module."""
        # Do not react to parameter node changes (GUI will be updated when the user enters into the module)
        if self._parameterNode:
            self._parameterNode.disconnectGui(self._parameterNodeGuiTag)
            self._parameterNodeGuiTag = None
            self.removeObserver(self._parameterNode, vtk.vtkCommand.ModifiedEvent, self._checkCanApply)
        
    def onSceneStartClose(self, caller, event) -> None:
        """Called just before the scene is closed."""
        # Parameter node will be reset, do not use it anymore
        self.setParameterNode(None)
    
    def onSceneEndClose(self, caller, event) -> None:
        """Called just after the scene is closed."""
        # If this module is shown while the scene is closed then recreate a new parameter node immediately
        if self.parent.isEntered:
            self.initializeParameterNode()
            
    def initializeParameterNode(self) -> None:
        """Ensure parameter node exists and observed."""
        # Parameter node stores all user choices in parameter values, node selections, etc.
        # so that when the scene is saved and reloaded, these settings are restored.

        self.setParameterNode(self.logic.getParameterNode())

        # Select default input nodes if nothing is selected yet to save a few clicks for the user
        if not self._parameterNode.inputVolume:
            firstVolumeNode = slicer.mrmlScene.GetFirstNodeByClass("vtkMRMLScalarVolumeNode")
            if firstVolumeNode:
                self._parameterNode.inputVolume = firstVolumeNode
                
    def setParameterNode(self, inputParameterNode: Optional[VesselTreeGeneratorParameterNode]) -> None:
        """
        Set and observe parameter node.
        Observation is needed because when the parameter node is changed then the GUI must be updated immediately.
        """

        if self._parameterNode:
            self._parameterNode.disconnectGui(self._parameterNodeGuiTag)
            self.removeObserver(self._parameterNode, vtk.vtkCommand.ModifiedEvent, self._checkCanApply)
        self._parameterNode = inputParameterNode
        if self._parameterNode:
            # Note: in the .ui file, a Qt dynamic property called "SlicerParameterName" is set on each
            # ui element that needs connection.
            self._parameterNodeGuiTag = self._parameterNode.connectGui(self.ui)
            self.addObserver(self._parameterNode, vtk.vtkCommand.ModifiedEvent, self._checkCanApply)
            self._checkCanApply()
            
    def _checkCanApply(self, caller=None, event=None) -> None:
        pass
            
    def onApplyButton(self) -> None:
        """Run processing when user clicks "Apply" button."""
        with slicer.util.tryWithErrorDisplay(_("Failed to compute results."), waitCursor=True):
            # Compute output
            self.logic.process(self.ui.inputSelector.currentNode(), self.ui.outputSelector.currentNode(),
                               self.ui.imageThresholdSliderWidget.value, self.ui.invertOutputCheckBox.checked)

            # Compute inverted output (if needed)
            if self.ui.invertedOutputSelector.currentNode():
                # If additional output volume is selected then result with inverted threshold is written there
                self.logic.process(self.ui.inputSelector.currentNode(), self.ui.invertedOutputSelector.currentNode(),
                                   self.ui.imageThresholdSliderWidget.value, not self.ui.invertOutputCheckBox.checked, showResult=False)
  
    def onNoiseReductionLow(self, checked: bool) -> None:
        # set R=1 
        if checked:
            self._medianRadius = 1
          
    def onNoiseReductionHigh(self, checked: bool) -> None:
        # set R=2
        if checked:
            self._medianRadius = 2
             
    def onApplySettings(self) -> None:
        print("DEBUG: onApplySettings called")
        # Apply settings when apply is clicked 
        with slicer.util.tryWithErrorDisplay(_("Failed to apply settings."), waitCursor=True):
            
            # Set I/O
            inputVolume = self.ui.inputSelector.currentNode()
            outputVolume = self.ui.outputSelector.currentNode()
            
            if not inputVolume or not outputVolume:
                raise ValueError("No volumes selected!")
            
            # Decide what radius to apply
            medianRadius = self._medianRadius
            
            # sigmoid will take this as input 
            medianResultNode = inputVolume 
            
            # if radius is chosen 
            tempMedianNode = None
            
            if medianRadius is not None:
                # user request for intermediate volume 
                if self._parameterNode.saveIntermediateVolume:
                    scene = slicer.mrmlScene
                    existingNode = scene.GetFirstNodeByName("intermediate_median")
                    
                    # if intermediate volume is already there
                    if existingNode:
                        intermediateNode = existingNode
                    else:
                        intermediateNode = scene.AddNewNodeByClass("vtkMRMLScalarVolumeNode", "intermediate_median")
                        
                    self.logic.applyMedianFilter(inputVolume, intermediateNode, medianRadius, showResults=False)
                    
                    medianResultNode = intermediateNode
                    
                else:
                    # no intermediate volume requested by user
                    tempMedianNode = slicer.mrmlScene.AddNewNodeByClass("vtkMRMLScalarVolumeNode", "TempMedianForSigmoid")
                    self.logic.applyMedianFilter(inputVolume, tempMedianNode, medianRadius, showResults=False)
                    
                    medianResultNode = tempMedianNode
                    
            alpha = self.ui.SliderWidgetAlpha.value
            beta = self.ui.SliderWidgetBeta.value
            
            # apply sigmoid on output median
            self.logic.applySigmoidFilter(medianResultNode, outputVolume, alpha, beta)
            
            # show
            slicer.util.setSliceViewerLayers(background=outputVolume, fit=True)

            # Clean up temp node if we used one
            if tempMedianNode is not None:
                slicer.mrmlScene.RemoveNode(tempMedianNode)
                                     
    def onAddSegmentation(self) -> None:
        """
        Create (or reuse) a segmentation node based on the current output volume,
        and prepare a 'Vessels' segment for thresholding.
        """
        with slicer.util.tryWithErrorDisplay("Failed to create segmentation.", waitCursor=True):
            volumeNode = self.ui.outputSelector.currentNode()
            if not volumeNode:
                raise ValueError("Please select an Output volume first.")

            scene = slicer.mrmlScene

            # Create segmentation node if needed
            if not self._segmentationNode3D:
                self._segmentationNode3D = scene.AddNewNodeByClass(
                    "vtkMRMLSegmentationNode", "VesselsSegmentation"
                )

            self._segmentationNode3D.CreateDefaultDisplayNodes()
            displayNode = self._segmentationNode3D.GetDisplayNode()
            displayNode.SetVisibility2D(True)
            displayNode.SetVisibility3D(False)

            segmentation = self._segmentationNode3D.GetSegmentation()

            # Create or reuse segment
            if not self._segmentId3D or not segmentation.GetSegment(self._segmentId3D):
                self._segmentId3D = segmentation.AddEmptySegment("Vessels")

            # Hook into hidden Segment Editor
            w = self.segmentEditorWidget3D
            w.setSegmentationNode(self._segmentationNode3D)
            w.setSourceVolumeNode(volumeNode)
            w.setCurrentSegmentID(self._segmentId3D)
            w.setActiveEffectByName("Threshold")

            # Show volume + segmentation in slice views
            slicer.util.setSliceViewerLayers(background=volumeNode, label=self._segmentationNode3D, fit=True)

            # Initialize the range widget ONLY by setting numbers (no MRML linking)
            low, high = volumeNode.GetImageData().GetScalarRange()
            rw = self.ui.rangeWidgetThreshold
            rw.blockSignals(True)
            rw.setRange(low, high)
            rw.setMinimumValue(low)
            rw.setMaximumValue(high)
            rw.blockSignals(False)

            # Also remember these as current threshold values
            self._lastThresholdMin = low
            self._lastThresholdMax = high
   
    def onThresholdValuesChanged(self, minimum: float, maximum: float) -> None:
        # Remember for 'Apply Threshold' button
        self._lastThresholdMin = minimum
        self._lastThresholdMax = maximum

        if not self._segmentationNode3D or not self._segmentId3D:
            # No segmentation yet → nothing to preview
            return

        volumeNode = self.ui.outputSelector.currentNode()
        if not volumeNode:
            return

        w = self.segmentEditorWidget3D
        w.setSegmentationNode(self._segmentationNode3D)
        w.setSourceVolumeNode(volumeNode)
        w.setCurrentSegmentID(self._segmentId3D)

        w.setActiveEffectByName("Threshold")
        effect = w.activeEffect()
        if not effect:
            raise RuntimeError("Threshold effect is not available")

        # Update effect parameters from slider
        effect.setParameter("MinimumThreshold", f"{minimum:g}")
        effect.setParameter("MaximumThreshold", f"{maximum:g}")

        # For PREVIEW we do NOT call onApply() – the effect will redraw
        # its preview overlay automatically based on parameters.
        slicer.app.processEvents()

    def onApplyThresholdShow3D(self) -> None:
        """
        Single button:
        - apply threshold using last slider values
        - keep largest island
        - generate and show 3D model
        - show success popup if everything worked
        """
        try:
            # Basic checks
            if self._lastThresholdMin is None or self._lastThresholdMax is None:
                slicer.util.errorDisplay("Move the threshold slider at least once.")
                return

            if not self._segmentationNode3D or not self._segmentId3D:
                raise ValueError("No segmentation. Use 'Add Segmentation' first.")

            volumeNode = self.ui.outputSelector.currentNode()
            if not volumeNode:
                raise ValueError("Please select an Output volume.")

            # Prepare Segment Editor widget 
            w = self.segmentEditorWidget3D
            w.setSegmentationNode(self._segmentationNode3D)
            w.setSourceVolumeNode(volumeNode)
            w.setCurrentSegmentID(self._segmentId3D)

            # Apply Threshold into the segment 
            w.setActiveEffectByName("Threshold")
            effect = w.activeEffect()
            if not effect:
                raise RuntimeError("Threshold effect is not available")

            effect.setParameter("MinimumThreshold", f"{self._lastThresholdMin:g}")
            effect.setParameter("MaximumThreshold", f"{self._lastThresholdMax:g}")

            # Actually write mask into the segment
            effect.self().onApply()

            # Keep largest island 
            w.setActiveEffectByName("Islands")
            effect = w.activeEffect()
            if not effect:
                raise RuntimeError("Islands effect is not available")

            effect.setParameter("Operation", "KEEP_LARGEST_ISLAND")
            effect.setParameter("MinimumSize", "1000")
            effect.self().onApply()
            
            # Deselect any SegmentEditor Effect 
            w.setActiveEffect(None)

            # Make sure closed surface is generated and shown in 3D 
            segNode = self._segmentationNode3D
            segNode.CreateDefaultDisplayNodes()
            segDisplayNode = segNode.GetDisplayNode()

            # Ensure closed surface representation exists
            segNode.CreateClosedSurfaceRepresentation()

            # Turn 3D visibility ON
            segDisplayNode.SetVisibility3D(True)
            segDisplayNode.SetPreferredDisplayRepresentationName3D("Closed surface")

            # Also ensure segmentation is visible
            segNode.SetDisplayVisibility(1)

            # Center 3D view on the segmentation
            layoutManager = slicer.app.layoutManager()
            threeDWidget = layoutManager.threeDWidget(0)
            threeDView = threeDWidget.threeDView()
            threeDView.resetCamera()
            
            # collect params for infoDisplay
            medianRadius = self._medianRadius if self._medianRadius is not None else "None"
            alpha = self.ui.SliderWidgetAlpha.value
            beta = self.ui.SliderWidgetBeta.value
            thMin = self._lastThresholdMin
            thMax = self._lastThresholdMax

        except Exception as e:
            slicer.util.errorDisplay(f"Failed to apply threshold and show 3D model.\n{e}")
            return

        # Only shown if everything above succeeded
        message = (
                    "Vessel Tree successfully created!\n\n"
                    f"Median radius: {medianRadius}\n"
                    f"Sigmoid Alpha: {alpha:g}\n"
                    f"Sigmoid Beta: {beta:g}\n"
                    f"Threshold Min: {thMin:g}\n"
                    f"Threshold Max: {thMax:g}"
                    )
        
        slicer.util.infoDisplay(message)

    def onComputeMaurerDistance(self) -> None:
        
        with slicer.util.tryWithErrorDisplay("Failed to compute Maurer Distance.", waitCursor=True):
            
            # Segementation node is set as as source volume -> NodeComboBox: "inputSelectorSegmentation"
            segmentationNode = self.ui.inputSelectorSegmentation.currentNode()
            if not segmentationNode:
                raise ValueError("Please select a Segmentation node from Step 2 first.")
            
            if not segmentationNode.IsA("vtkMRMLSegmentationNode"): 
                raise TypeError("Input node must be a Segmentation Node.")
            
            # Set the reference volume to the "output" volume of Step 1
            refVolume = self.ui.outputSelector.currentNode()
            if not refVolume:
                raise ValueError("Please select an Output volume from Step 1 first.")
            
            # get the segmentation from the node
            segmentation = segmentationNode.GetSegmentation()
            if segmentation.GetNumberOfSegments() < 1:
                raise ValueError("The selected segmentation node does not contain any segments.")
            
            scene = slicer.mrmlScene
            
            # create labelmap volume from segmentation
            labelmapNode = slicer.mrmlScene.AddNewNodeByClass("vtkMRMLLabelMapVolumeNode", "Vessels_Labelmap")
            if not labelmapNode:
                raise RuntimeError("Failed to create labelmap volume node.")
            
            # Export segmentations 
            segmentIDs = vtk.vtkStringArray()
            segmentationNode.GetSegmentation().GetSegmentIDs(segmentIDs)
            
            slicer.modules.segmentations.logic().ExportSegmentsToLabelmapNode(
                segmentationNode,
                segmentIDs, 
                labelmapNode,
                refVolume
            ) 
            
            
            # --- Enforce binary labelmap (0/1) ---
            # Segment export can produce labels 1..N; MaurerDistance expects binary.
            LabelMapImg = sitkUtils.PullVolumeFromSlicer(labelmapNode)
            LabelMapBinary = sitk.Cast(LabelMapImg > 0, sitk.sitkUInt8)
            sitkUtils.PushVolumeToSlicer(LabelMapBinary, targetNode=labelmapNode)
            
            # creat maurer distance output volume
            outName = f"{segmentationNode.GetName()}_MaurerDistance"
            maurerOutputNode = scene.AddNewNodeByClass("vtkMRMLScalarVolumeNode", outName)
            
            if not maurerOutputNode:
                raise RuntimeError("Failed to create Maurer distance output volume node.")
            
            # Compute Maurer Distance
            self.logic.MaurerDistance(labelmapNode, maurerOutputNode, showResults=True)
        
        
            # set LUT "HotToColdRainbow" for better visualization
            colorNde = slicer.util.getNode("HotToColdRainbow")
            maurerOutputNode.GetDisplayNode().SetAndObserveColorNodeID(colorNde.GetID())
            maurerOutputNode.GetDisplayNode().Modified()
            maurerOutputNode.Modified()



# ================================
# VesselTreeGeneratorLogic
# ================================


class VesselTreeGeneratorLogic(ScriptedLoadableModuleLogic):
    """This class should implement all the actual
    computation done by your module.  The interface
    should be such that other python code can import
    this class and make use of the functionality without
    requiring an instance of the Widget.
    Uses ScriptedLoadableModuleLogic base class, available at:
    https://github.com/Slicer/Slicer/blob/main/Base/Python/slicer/ScriptedLoadableModule.py
    """

    def __init__(self) -> None:
        """Called when the logic class is instantiated. Can be used for initializing member variables."""
        ScriptedLoadableModuleLogic.__init__(self)

    def getParameterNode(self):
        return VesselTreeGeneratorParameterNode(super().getParameterNode())

    def applyMedianFilter(self, 
                          inputVolume: vtkMRMLScalarVolumeNode, 
                          outputVolume: vtkMRMLScalarVolumeNode, 
                          radius: int, 
                          showResults: bool = True ) -> None:
        
        if not inputVolume or not outputVolume:
            raise ValueError("Input or output volume is invalid")
    
        import time, logging
        startTime = time.time()
        logging.info(f"Median filter started (radius={radius})")
        
        # Pull slicer volume into SITK image 
        inputImage = sitkUtils.PullVolumeFromSlicer(inputVolume)
        
        # Median Filter
        medianFilter = sitk.MedianImageFilter()
        medianFilter.SetRadius(radius)
        outputImage = medianFilter.Execute(inputImage)
        
        # Push back to Slicer 
        sitkUtils.PushVolumeToSlicer(outputImage, targetNode = outputVolume)
        
        if showResults:
            slicer.util.setSliceViewerLayers(background=outputVolume, fit=True)
            
        logging.info(f"Median filter completed")
    
    def applySigmoidFilter(self, 
                           inputVolume: vtkMRMLScalarVolumeNode, 
                           outputVolume: vtkMRMLScalarVolumeNode, 
                           alpha: float, 
                           beta: float, 
                           outputMinimum: float = 0, 
                           outputMaximum: float = 1, 
                           showResults: bool = True) -> None:
        
        if not inputVolume or not outputVolume:
            raise ValueError("Input or output volume is invalid")
        
        # pull slicer vol into sitk
        inputImage = sitkUtils.PullVolumeFromSlicer(inputVolume)
        
        # Sigmoid Filter 
        sigmoidFilter = sitk.SigmoidImageFilter()
        sigmoidFilter.SetAlpha(alpha)
        sigmoidFilter.SetBeta(beta)
        sigmoidFilter.SetOutputMaximum(outputMaximum)
        sigmoidFilter.SetOutputMinimum(outputMinimum)
        outputImage = sigmoidFilter.Execute(inputImage)
        
        # Push back to Slicer 
        sitkUtils.PushVolumeToSlicer(outputImage, targetNode = outputVolume)
        
        if showResults:
            slicer.util.setSliceViewerLayers(background=outputVolume, fit=True)
            
    def MaurerDistance(self,
                       inputVolume: vtkMRMLLabelMapVolumeNode, 
                       outputVolume: vtkMRMLScalarVolumeNode, 
                       showResults: bool = True) -> None:
        
        if not inputVolume or not outputVolume:
            raise ValueError("Input or output volume is invalid")
        
            # Must be a labelmap volume node
        if not inputVolume.IsA("vtkMRMLLabelMapVolumeNode"):
            raise TypeError(f"Input volume must be a binary labelmap. " f"Got {inputVolume.GetClassName()}.")
        
        # pull slicer vol into sitk
        inputImage = sitkUtils.PullVolumeFromSlicer(inputVolume)
        
        # Ensure correct type (optional but safe)
        #binary = sitk.Cast(inputImage > 0, sitk.sitkUInt8)
        
        # Maurer Distance Filter
        maurerFilter = sitk.SignedMaurerDistanceMapImageFilter()
        maurerFilter.SetUseImageSpacing(True)
        maurerFilter.SetSquaredDistance(False)
        maurerFilter.SetBackgroundValue(0)
        maurerFilter.SetInsideIsPositive(False)
        
        outputImage = maurerFilter.Execute(inputImage)
        
        # push back to Slicer
        sitkUtils.PushVolumeToSlicer(outputImage, targetNode = outputVolume)
        
        if showResults:
            slicer.util.setSliceViewerLayers(background=outputVolume, fit=True)
            
        
        
# ================================
# VesselTreeGeneratorTest
# ================================


class VesselTreeGeneratorTest(ScriptedLoadableModuleTest):
    """
    This is the test case for your scripted module.
    Uses ScriptedLoadableModuleTest base class, available at:
    https://github.com/Slicer/Slicer/blob/main/Base/Python/slicer/ScriptedLoadableModule.py
    """

    def setUp(self):
        """Do whatever is needed to reset the state - typically a scene clear will be enough."""
        slicer.mrmlScene.Clear()

    def runTest(self):
        """Run as few or as many tests as needed here."""
        self.setUp()
        #self.test_VesselTreeGenerator1()

    '''
    def test_VesselTreeGenerator1(self):
        """Ideally you should have several levels of tests.  At the lowest level
        tests should exercise the functionality of the logic with different inputs
        (both valid and invalid).  At higher levels your tests should emulate the
        way the user would interact with your code and confirm that it still works
        the way you intended.
        One of the most important features of the tests is that it should alert other
        developers when their changes will have an impact on the behavior of your
        module.  For example, if a developer removes a feature that you depend on,
        your test should break so they know that the feature is needed.
        """

        self.delayDisplay("Starting the test")

        # Get/create input data

        import SampleData

        registerSampleData()
        inputVolume = SampleData.downloadSample("VesselTreeGenerator1")
        self.delayDisplay("Loaded test data set")

        inputScalarRange = inputVolume.GetImageData().GetScalarRange()
        self.assertEqual(inputScalarRange[0], 0)
        self.assertEqual(inputScalarRange[1], 695)

        outputVolume = slicer.mrmlScene.AddNewNodeByClass("vtkMRMLScalarVolumeNode")
        threshold = 100

        # Test the module logic

        logic = VesselTreeGeneratorLogic()

        # Test algorithm with non-inverted threshold
        logic.process(inputVolume, outputVolume, threshold, True)
        outputScalarRange = outputVolume.GetImageData().GetScalarRange()
        self.assertEqual(outputScalarRange[0], inputScalarRange[0])
        self.assertEqual(outputScalarRange[1], threshold)

        # Test algorithm with inverted threshold
        logic.process(inputVolume, outputVolume, threshold, False)
        outputScalarRange = outputVolume.GetImageData().GetScalarRange()
        self.assertEqual(outputScalarRange[0], inputScalarRange[0])
        self.assertEqual(outputScalarRange[1], inputScalarRange[1])

        self.delayDisplay("Test passed")
    '''