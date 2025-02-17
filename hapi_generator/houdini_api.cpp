

#include "houdini_api.h"
#include "hego_platform.h"    

  HoudiniApi::CreateInProcessSessionFuncPtr
  HoudiniApi::CreateInProcessSession = &HoudiniApi::CreateInProcessSessionEmptyStub;
  
  HoudiniApi::StartThriftSocketServerFuncPtr
  HoudiniApi::StartThriftSocketServer = &HoudiniApi::StartThriftSocketServerEmptyStub;
  
  HoudiniApi::CreateThriftSocketSessionFuncPtr
  HoudiniApi::CreateThriftSocketSession = &HoudiniApi::CreateThriftSocketSessionEmptyStub;
  
  HoudiniApi::StartThriftNamedPipeServerFuncPtr
  HoudiniApi::StartThriftNamedPipeServer = &HoudiniApi::StartThriftNamedPipeServerEmptyStub;
  
  HoudiniApi::CreateThriftNamedPipeSessionFuncPtr
  HoudiniApi::CreateThriftNamedPipeSession = &HoudiniApi::CreateThriftNamedPipeSessionEmptyStub;
  
  HoudiniApi::StartThriftSharedMemoryServerFuncPtr
  HoudiniApi::StartThriftSharedMemoryServer = &HoudiniApi::StartThriftSharedMemoryServerEmptyStub;
  
  HoudiniApi::CreateThriftSharedMemorySessionFuncPtr
  HoudiniApi::CreateThriftSharedMemorySession = &HoudiniApi::CreateThriftSharedMemorySessionEmptyStub;
  
  HoudiniApi::BindCustomImplementationFuncPtr
  HoudiniApi::BindCustomImplementation = &HoudiniApi::BindCustomImplementationEmptyStub;
  
  HoudiniApi::CreateCustomSessionFuncPtr
  HoudiniApi::CreateCustomSession = &HoudiniApi::CreateCustomSessionEmptyStub;
  
  HoudiniApi::IsSessionValidFuncPtr
  HoudiniApi::IsSessionValid = &HoudiniApi::IsSessionValidEmptyStub;
  
  HoudiniApi::CloseSessionFuncPtr
  HoudiniApi::CloseSession = &HoudiniApi::CloseSessionEmptyStub;
  
  HoudiniApi::IsInitializedFuncPtr
  HoudiniApi::IsInitialized = &HoudiniApi::IsInitializedEmptyStub;
  
  HoudiniApi::InitializeFuncPtr
  HoudiniApi::Initialize = &HoudiniApi::InitializeEmptyStub;
  
  HoudiniApi::CleanupFuncPtr
  HoudiniApi::Cleanup = &HoudiniApi::CleanupEmptyStub;
  
  HoudiniApi::ShutdownFuncPtr
  HoudiniApi::Shutdown = &HoudiniApi::ShutdownEmptyStub;
  
  HoudiniApi::StartPerformanceMonitorProfileFuncPtr
  HoudiniApi::StartPerformanceMonitorProfile = &HoudiniApi::StartPerformanceMonitorProfileEmptyStub;
  
  HoudiniApi::StopPerformanceMonitorProfileFuncPtr
  HoudiniApi::StopPerformanceMonitorProfile = &HoudiniApi::StopPerformanceMonitorProfileEmptyStub;
  
  HoudiniApi::GetEnvIntFuncPtr
  HoudiniApi::GetEnvInt = &HoudiniApi::GetEnvIntEmptyStub;
  
  HoudiniApi::GetSessionEnvIntFuncPtr
  HoudiniApi::GetSessionEnvInt = &HoudiniApi::GetSessionEnvIntEmptyStub;
  
  HoudiniApi::GetServerEnvIntFuncPtr
  HoudiniApi::GetServerEnvInt = &HoudiniApi::GetServerEnvIntEmptyStub;
  
  HoudiniApi::GetServerEnvStringFuncPtr
  HoudiniApi::GetServerEnvString = &HoudiniApi::GetServerEnvStringEmptyStub;
  
  HoudiniApi::GetServerEnvVarCountFuncPtr
  HoudiniApi::GetServerEnvVarCount = &HoudiniApi::GetServerEnvVarCountEmptyStub;
  
  HoudiniApi::GetServerEnvVarListFuncPtr
  HoudiniApi::GetServerEnvVarList = &HoudiniApi::GetServerEnvVarListEmptyStub;
  
  HoudiniApi::SetServerEnvIntFuncPtr
  HoudiniApi::SetServerEnvInt = &HoudiniApi::SetServerEnvIntEmptyStub;
  
  HoudiniApi::SetServerEnvStringFuncPtr
  HoudiniApi::SetServerEnvString = &HoudiniApi::SetServerEnvStringEmptyStub;
  
  HoudiniApi::GetStatusFuncPtr
  HoudiniApi::GetStatus = &HoudiniApi::GetStatusEmptyStub;
  
  HoudiniApi::GetStatusStringBufLengthFuncPtr
  HoudiniApi::GetStatusStringBufLength = &HoudiniApi::GetStatusStringBufLengthEmptyStub;
  
  HoudiniApi::GetStatusStringFuncPtr
  HoudiniApi::GetStatusString = &HoudiniApi::GetStatusStringEmptyStub;
  
  HoudiniApi::ComposeNodeCookResultFuncPtr
  HoudiniApi::ComposeNodeCookResult = &HoudiniApi::ComposeNodeCookResultEmptyStub;
  
  HoudiniApi::GetComposedNodeCookResultFuncPtr
  HoudiniApi::GetComposedNodeCookResult = &HoudiniApi::GetComposedNodeCookResultEmptyStub;
  
  HoudiniApi::GetNodeCookResultLengthFuncPtr
  HoudiniApi::GetNodeCookResultLength = &HoudiniApi::GetNodeCookResultLengthEmptyStub;
  
  HoudiniApi::GetNodeCookResultFuncPtr
  HoudiniApi::GetNodeCookResult = &HoudiniApi::GetNodeCookResultEmptyStub;
  
  HoudiniApi::GetMessageNodeCountFuncPtr
  HoudiniApi::GetMessageNodeCount = &HoudiniApi::GetMessageNodeCountEmptyStub;
  
  HoudiniApi::GetMessageNodeIdsFuncPtr
  HoudiniApi::GetMessageNodeIds = &HoudiniApi::GetMessageNodeIdsEmptyStub;
  
  HoudiniApi::CheckForSpecificErrorsFuncPtr
  HoudiniApi::CheckForSpecificErrors = &HoudiniApi::CheckForSpecificErrorsEmptyStub;
  
  HoudiniApi::ClearConnectionErrorFuncPtr
  HoudiniApi::ClearConnectionError = &HoudiniApi::ClearConnectionErrorEmptyStub;
  
  HoudiniApi::GetConnectionErrorLengthFuncPtr
  HoudiniApi::GetConnectionErrorLength = &HoudiniApi::GetConnectionErrorLengthEmptyStub;
  
  HoudiniApi::GetConnectionErrorFuncPtr
  HoudiniApi::GetConnectionError = &HoudiniApi::GetConnectionErrorEmptyStub;
  
  HoudiniApi::GetCookingTotalCountFuncPtr
  HoudiniApi::GetCookingTotalCount = &HoudiniApi::GetCookingTotalCountEmptyStub;
  
  HoudiniApi::GetCookingCurrentCountFuncPtr
  HoudiniApi::GetCookingCurrentCount = &HoudiniApi::GetCookingCurrentCountEmptyStub;
  
  HoudiniApi::InterruptFuncPtr
  HoudiniApi::Interrupt = &HoudiniApi::InterruptEmptyStub;
  
  HoudiniApi::ConvertTransformFuncPtr
  HoudiniApi::ConvertTransform = &HoudiniApi::ConvertTransformEmptyStub;
  
  HoudiniApi::ConvertMatrixToQuatFuncPtr
  HoudiniApi::ConvertMatrixToQuat = &HoudiniApi::ConvertMatrixToQuatEmptyStub;
  
  HoudiniApi::ConvertMatrixToEulerFuncPtr
  HoudiniApi::ConvertMatrixToEuler = &HoudiniApi::ConvertMatrixToEulerEmptyStub;
  
  HoudiniApi::ConvertTransformQuatToMatrixFuncPtr
  HoudiniApi::ConvertTransformQuatToMatrix = &HoudiniApi::ConvertTransformQuatToMatrixEmptyStub;
  
  HoudiniApi::ConvertTransformEulerToMatrixFuncPtr
  HoudiniApi::ConvertTransformEulerToMatrix = &HoudiniApi::ConvertTransformEulerToMatrixEmptyStub;
  
  HoudiniApi::PythonThreadInterpreterLockFuncPtr
  HoudiniApi::PythonThreadInterpreterLock = &HoudiniApi::PythonThreadInterpreterLockEmptyStub;
  
  HoudiniApi::GetStringBufLengthFuncPtr
  HoudiniApi::GetStringBufLength = &HoudiniApi::GetStringBufLengthEmptyStub;
  
  HoudiniApi::GetStringFuncPtr
  HoudiniApi::GetString = &HoudiniApi::GetStringEmptyStub;
  
  HoudiniApi::SetCustomStringFuncPtr
  HoudiniApi::SetCustomString = &HoudiniApi::SetCustomStringEmptyStub;
  
  HoudiniApi::RemoveCustomStringFuncPtr
  HoudiniApi::RemoveCustomString = &HoudiniApi::RemoveCustomStringEmptyStub;
  
  HoudiniApi::GetStringBatchSizeFuncPtr
  HoudiniApi::GetStringBatchSize = &HoudiniApi::GetStringBatchSizeEmptyStub;
  
  HoudiniApi::GetStringBatchFuncPtr
  HoudiniApi::GetStringBatch = &HoudiniApi::GetStringBatchEmptyStub;
  
  HoudiniApi::GetTimeFuncPtr
  HoudiniApi::GetTime = &HoudiniApi::GetTimeEmptyStub;
  
  HoudiniApi::SetTimeFuncPtr
  HoudiniApi::SetTime = &HoudiniApi::SetTimeEmptyStub;
  
  HoudiniApi::GetUseHoudiniTimeFuncPtr
  HoudiniApi::GetUseHoudiniTime = &HoudiniApi::GetUseHoudiniTimeEmptyStub;
  
  HoudiniApi::SetUseHoudiniTimeFuncPtr
  HoudiniApi::SetUseHoudiniTime = &HoudiniApi::SetUseHoudiniTimeEmptyStub;
  
  HoudiniApi::GetTimelineOptionsFuncPtr
  HoudiniApi::GetTimelineOptions = &HoudiniApi::GetTimelineOptionsEmptyStub;
  
  HoudiniApi::SetTimelineOptionsFuncPtr
  HoudiniApi::SetTimelineOptions = &HoudiniApi::SetTimelineOptionsEmptyStub;
  
  HoudiniApi::GetCompositorOptionsFuncPtr
  HoudiniApi::GetCompositorOptions = &HoudiniApi::GetCompositorOptionsEmptyStub;
  
  HoudiniApi::SetCompositorOptionsFuncPtr
  HoudiniApi::SetCompositorOptions = &HoudiniApi::SetCompositorOptionsEmptyStub;
  
  HoudiniApi::LoadAssetLibraryFromFileFuncPtr
  HoudiniApi::LoadAssetLibraryFromFile = &HoudiniApi::LoadAssetLibraryFromFileEmptyStub;
  
  HoudiniApi::LoadAssetLibraryFromMemoryFuncPtr
  HoudiniApi::LoadAssetLibraryFromMemory = &HoudiniApi::LoadAssetLibraryFromMemoryEmptyStub;
  
  HoudiniApi::GetAvailableAssetCountFuncPtr
  HoudiniApi::GetAvailableAssetCount = &HoudiniApi::GetAvailableAssetCountEmptyStub;
  
  HoudiniApi::GetAvailableAssetsFuncPtr
  HoudiniApi::GetAvailableAssets = &HoudiniApi::GetAvailableAssetsEmptyStub;
  
  HoudiniApi::GetAssetInfoFuncPtr
  HoudiniApi::GetAssetInfo = &HoudiniApi::GetAssetInfoEmptyStub;
  
  HoudiniApi::GetAssetDefinitionParmCountsFuncPtr
  HoudiniApi::GetAssetDefinitionParmCounts = &HoudiniApi::GetAssetDefinitionParmCountsEmptyStub;
  
  HoudiniApi::GetAssetDefinitionParmInfosFuncPtr
  HoudiniApi::GetAssetDefinitionParmInfos = &HoudiniApi::GetAssetDefinitionParmInfosEmptyStub;
  
  HoudiniApi::GetAssetDefinitionParmValuesFuncPtr
  HoudiniApi::GetAssetDefinitionParmValues = &HoudiniApi::GetAssetDefinitionParmValuesEmptyStub;
  
  HoudiniApi::GetAssetDefinitionParmTagNameFuncPtr
  HoudiniApi::GetAssetDefinitionParmTagName = &HoudiniApi::GetAssetDefinitionParmTagNameEmptyStub;
  
  HoudiniApi::GetAssetDefinitionParmTagValueFuncPtr
  HoudiniApi::GetAssetDefinitionParmTagValue = &HoudiniApi::GetAssetDefinitionParmTagValueEmptyStub;
  
  HoudiniApi::GetLoadedAssetLibraryCountFuncPtr
  HoudiniApi::GetLoadedAssetLibraryCount = &HoudiniApi::GetLoadedAssetLibraryCountEmptyStub;
  
  HoudiniApi::GetAssetLibraryIdsFuncPtr
  HoudiniApi::GetAssetLibraryIds = &HoudiniApi::GetAssetLibraryIdsEmptyStub;
  
  HoudiniApi::GetAssetLibraryFilePathFuncPtr
  HoudiniApi::GetAssetLibraryFilePath = &HoudiniApi::GetAssetLibraryFilePathEmptyStub;
  
  HoudiniApi::LoadHIPFileFuncPtr
  HoudiniApi::LoadHIPFile = &HoudiniApi::LoadHIPFileEmptyStub;
  
  HoudiniApi::MergeHIPFileFuncPtr
  HoudiniApi::MergeHIPFile = &HoudiniApi::MergeHIPFileEmptyStub;
  
  HoudiniApi::SaveHIPFileFuncPtr
  HoudiniApi::SaveHIPFile = &HoudiniApi::SaveHIPFileEmptyStub;
  
  HoudiniApi::GetHIPFileNodeCountFuncPtr
  HoudiniApi::GetHIPFileNodeCount = &HoudiniApi::GetHIPFileNodeCountEmptyStub;
  
  HoudiniApi::GetHIPFileNodeIdsFuncPtr
  HoudiniApi::GetHIPFileNodeIds = &HoudiniApi::GetHIPFileNodeIdsEmptyStub;
  
  HoudiniApi::IsNodeValidFuncPtr
  HoudiniApi::IsNodeValid = &HoudiniApi::IsNodeValidEmptyStub;
  
  HoudiniApi::GetNodeInfoFuncPtr
  HoudiniApi::GetNodeInfo = &HoudiniApi::GetNodeInfoEmptyStub;
  
  HoudiniApi::GetNodePathFuncPtr
  HoudiniApi::GetNodePath = &HoudiniApi::GetNodePathEmptyStub;
  
  HoudiniApi::GetManagerNodeIdFuncPtr
  HoudiniApi::GetManagerNodeId = &HoudiniApi::GetManagerNodeIdEmptyStub;
  
  HoudiniApi::ComposeChildNodeListFuncPtr
  HoudiniApi::ComposeChildNodeList = &HoudiniApi::ComposeChildNodeListEmptyStub;
  
  HoudiniApi::GetComposedChildNodeListFuncPtr
  HoudiniApi::GetComposedChildNodeList = &HoudiniApi::GetComposedChildNodeListEmptyStub;
  
  HoudiniApi::CreateNodeFuncPtr
  HoudiniApi::CreateNode = &HoudiniApi::CreateNodeEmptyStub;
  
  HoudiniApi::CreateInputNodeFuncPtr
  HoudiniApi::CreateInputNode = &HoudiniApi::CreateInputNodeEmptyStub;
  
  HoudiniApi::CreateInputCurveNodeFuncPtr
  HoudiniApi::CreateInputCurveNode = &HoudiniApi::CreateInputCurveNodeEmptyStub;
  
  HoudiniApi::CreateHeightFieldInputFuncPtr
  HoudiniApi::CreateHeightFieldInput = &HoudiniApi::CreateHeightFieldInputEmptyStub;
  
  HoudiniApi::CreateHeightfieldInputVolumeNodeFuncPtr
  HoudiniApi::CreateHeightfieldInputVolumeNode = &HoudiniApi::CreateHeightfieldInputVolumeNodeEmptyStub;
  
  HoudiniApi::CookNodeFuncPtr
  HoudiniApi::CookNode = &HoudiniApi::CookNodeEmptyStub;
  
  HoudiniApi::DeleteNodeFuncPtr
  HoudiniApi::DeleteNode = &HoudiniApi::DeleteNodeEmptyStub;
  
  HoudiniApi::RenameNodeFuncPtr
  HoudiniApi::RenameNode = &HoudiniApi::RenameNodeEmptyStub;
  
  HoudiniApi::ConnectNodeInputFuncPtr
  HoudiniApi::ConnectNodeInput = &HoudiniApi::ConnectNodeInputEmptyStub;
  
  HoudiniApi::DisconnectNodeInputFuncPtr
  HoudiniApi::DisconnectNodeInput = &HoudiniApi::DisconnectNodeInputEmptyStub;
  
  HoudiniApi::QueryNodeInputFuncPtr
  HoudiniApi::QueryNodeInput = &HoudiniApi::QueryNodeInputEmptyStub;
  
  HoudiniApi::GetNodeInputNameFuncPtr
  HoudiniApi::GetNodeInputName = &HoudiniApi::GetNodeInputNameEmptyStub;
  
  HoudiniApi::DisconnectNodeOutputsAtFuncPtr
  HoudiniApi::DisconnectNodeOutputsAt = &HoudiniApi::DisconnectNodeOutputsAtEmptyStub;
  
  HoudiniApi::QueryNodeOutputConnectedCountFuncPtr
  HoudiniApi::QueryNodeOutputConnectedCount = &HoudiniApi::QueryNodeOutputConnectedCountEmptyStub;
  
  HoudiniApi::QueryNodeOutputConnectedNodesFuncPtr
  HoudiniApi::QueryNodeOutputConnectedNodes = &HoudiniApi::QueryNodeOutputConnectedNodesEmptyStub;
  
  HoudiniApi::GetNodeOutputNameFuncPtr
  HoudiniApi::GetNodeOutputName = &HoudiniApi::GetNodeOutputNameEmptyStub;
  
  HoudiniApi::GetNodeFromPathFuncPtr
  HoudiniApi::GetNodeFromPath = &HoudiniApi::GetNodeFromPathEmptyStub;
  
  HoudiniApi::GetOutputNodeIdFuncPtr
  HoudiniApi::GetOutputNodeId = &HoudiniApi::GetOutputNodeIdEmptyStub;
  
  HoudiniApi::GetParametersFuncPtr
  HoudiniApi::GetParameters = &HoudiniApi::GetParametersEmptyStub;
  
  HoudiniApi::GetParmInfoFuncPtr
  HoudiniApi::GetParmInfo = &HoudiniApi::GetParmInfoEmptyStub;
  
  HoudiniApi::GetParmIdFromNameFuncPtr
  HoudiniApi::GetParmIdFromName = &HoudiniApi::GetParmIdFromNameEmptyStub;
  
  HoudiniApi::GetParmInfoFromNameFuncPtr
  HoudiniApi::GetParmInfoFromName = &HoudiniApi::GetParmInfoFromNameEmptyStub;
  
  HoudiniApi::GetParmTagNameFuncPtr
  HoudiniApi::GetParmTagName = &HoudiniApi::GetParmTagNameEmptyStub;
  
  HoudiniApi::GetParmTagValueFuncPtr
  HoudiniApi::GetParmTagValue = &HoudiniApi::GetParmTagValueEmptyStub;
  
  HoudiniApi::ParmHasTagFuncPtr
  HoudiniApi::ParmHasTag = &HoudiniApi::ParmHasTagEmptyStub;
  
  HoudiniApi::ParmHasExpressionFuncPtr
  HoudiniApi::ParmHasExpression = &HoudiniApi::ParmHasExpressionEmptyStub;
  
  HoudiniApi::GetParmWithTagFuncPtr
  HoudiniApi::GetParmWithTag = &HoudiniApi::GetParmWithTagEmptyStub;
  
  HoudiniApi::GetParmExpressionFuncPtr
  HoudiniApi::GetParmExpression = &HoudiniApi::GetParmExpressionEmptyStub;
  
  HoudiniApi::RevertParmToDefaultFuncPtr
  HoudiniApi::RevertParmToDefault = &HoudiniApi::RevertParmToDefaultEmptyStub;
  
  HoudiniApi::RevertParmToDefaultsFuncPtr
  HoudiniApi::RevertParmToDefaults = &HoudiniApi::RevertParmToDefaultsEmptyStub;
  
  HoudiniApi::SetParmExpressionFuncPtr
  HoudiniApi::SetParmExpression = &HoudiniApi::SetParmExpressionEmptyStub;
  
  HoudiniApi::RemoveParmExpressionFuncPtr
  HoudiniApi::RemoveParmExpression = &HoudiniApi::RemoveParmExpressionEmptyStub;
  
  HoudiniApi::GetParmIntValueFuncPtr
  HoudiniApi::GetParmIntValue = &HoudiniApi::GetParmIntValueEmptyStub;
  
  HoudiniApi::GetParmIntValuesFuncPtr
  HoudiniApi::GetParmIntValues = &HoudiniApi::GetParmIntValuesEmptyStub;
  
  HoudiniApi::GetParmFloatValueFuncPtr
  HoudiniApi::GetParmFloatValue = &HoudiniApi::GetParmFloatValueEmptyStub;
  
  HoudiniApi::GetParmFloatValuesFuncPtr
  HoudiniApi::GetParmFloatValues = &HoudiniApi::GetParmFloatValuesEmptyStub;
  
  HoudiniApi::GetParmStringValueFuncPtr
  HoudiniApi::GetParmStringValue = &HoudiniApi::GetParmStringValueEmptyStub;
  
  HoudiniApi::GetParmStringValuesFuncPtr
  HoudiniApi::GetParmStringValues = &HoudiniApi::GetParmStringValuesEmptyStub;
  
  HoudiniApi::GetParmNodeValueFuncPtr
  HoudiniApi::GetParmNodeValue = &HoudiniApi::GetParmNodeValueEmptyStub;
  
  HoudiniApi::GetParmFileFuncPtr
  HoudiniApi::GetParmFile = &HoudiniApi::GetParmFileEmptyStub;
  
  HoudiniApi::GetParmChoiceListsFuncPtr
  HoudiniApi::GetParmChoiceLists = &HoudiniApi::GetParmChoiceListsEmptyStub;
  
  HoudiniApi::SetParmIntValueFuncPtr
  HoudiniApi::SetParmIntValue = &HoudiniApi::SetParmIntValueEmptyStub;
  
  HoudiniApi::SetParmIntValuesFuncPtr
  HoudiniApi::SetParmIntValues = &HoudiniApi::SetParmIntValuesEmptyStub;
  
  HoudiniApi::SetParmFloatValueFuncPtr
  HoudiniApi::SetParmFloatValue = &HoudiniApi::SetParmFloatValueEmptyStub;
  
  HoudiniApi::SetParmFloatValuesFuncPtr
  HoudiniApi::SetParmFloatValues = &HoudiniApi::SetParmFloatValuesEmptyStub;
  
  HoudiniApi::SetParmStringValueFuncPtr
  HoudiniApi::SetParmStringValue = &HoudiniApi::SetParmStringValueEmptyStub;
  
  HoudiniApi::SetParmNodeValueFuncPtr
  HoudiniApi::SetParmNodeValue = &HoudiniApi::SetParmNodeValueEmptyStub;
  
  HoudiniApi::InsertMultiparmInstanceFuncPtr
  HoudiniApi::InsertMultiparmInstance = &HoudiniApi::InsertMultiparmInstanceEmptyStub;
  
  HoudiniApi::RemoveMultiparmInstanceFuncPtr
  HoudiniApi::RemoveMultiparmInstance = &HoudiniApi::RemoveMultiparmInstanceEmptyStub;
  
  HoudiniApi::GetHandleInfoFuncPtr
  HoudiniApi::GetHandleInfo = &HoudiniApi::GetHandleInfoEmptyStub;
  
  HoudiniApi::GetHandleBindingInfoFuncPtr
  HoudiniApi::GetHandleBindingInfo = &HoudiniApi::GetHandleBindingInfoEmptyStub;
  
  HoudiniApi::GetPresetBufLengthFuncPtr
  HoudiniApi::GetPresetBufLength = &HoudiniApi::GetPresetBufLengthEmptyStub;
  
  HoudiniApi::GetPresetFuncPtr
  HoudiniApi::GetPreset = &HoudiniApi::GetPresetEmptyStub;
  
  HoudiniApi::SetPresetFuncPtr
  HoudiniApi::SetPreset = &HoudiniApi::SetPresetEmptyStub;
  
  HoudiniApi::GetPresetCountFuncPtr
  HoudiniApi::GetPresetCount = &HoudiniApi::GetPresetCountEmptyStub;
  
  HoudiniApi::GetPresetNamesFuncPtr
  HoudiniApi::GetPresetNames = &HoudiniApi::GetPresetNamesEmptyStub;
  
  HoudiniApi::GetObjectInfoFuncPtr
  HoudiniApi::GetObjectInfo = &HoudiniApi::GetObjectInfoEmptyStub;
  
  HoudiniApi::GetObjectTransformFuncPtr
  HoudiniApi::GetObjectTransform = &HoudiniApi::GetObjectTransformEmptyStub;
  
  HoudiniApi::ComposeObjectListFuncPtr
  HoudiniApi::ComposeObjectList = &HoudiniApi::ComposeObjectListEmptyStub;
  
  HoudiniApi::GetComposedObjectListFuncPtr
  HoudiniApi::GetComposedObjectList = &HoudiniApi::GetComposedObjectListEmptyStub;
  
  HoudiniApi::GetComposedObjectTransformsFuncPtr
  HoudiniApi::GetComposedObjectTransforms = &HoudiniApi::GetComposedObjectTransformsEmptyStub;
  
  HoudiniApi::GetInstancedObjectIdsFuncPtr
  HoudiniApi::GetInstancedObjectIds = &HoudiniApi::GetInstancedObjectIdsEmptyStub;
  
  HoudiniApi::GetInstanceTransformsOnPartFuncPtr
  HoudiniApi::GetInstanceTransformsOnPart = &HoudiniApi::GetInstanceTransformsOnPartEmptyStub;
  
  HoudiniApi::SetObjectTransformFuncPtr
  HoudiniApi::SetObjectTransform = &HoudiniApi::SetObjectTransformEmptyStub;
  
  HoudiniApi::GetDisplayGeoInfoFuncPtr
  HoudiniApi::GetDisplayGeoInfo = &HoudiniApi::GetDisplayGeoInfoEmptyStub;
  
  HoudiniApi::GetOutputGeoCountFuncPtr
  HoudiniApi::GetOutputGeoCount = &HoudiniApi::GetOutputGeoCountEmptyStub;
  
  HoudiniApi::GetOutputGeoInfosFuncPtr
  HoudiniApi::GetOutputGeoInfos = &HoudiniApi::GetOutputGeoInfosEmptyStub;
  
  HoudiniApi::GetGeoInfoFuncPtr
  HoudiniApi::GetGeoInfo = &HoudiniApi::GetGeoInfoEmptyStub;
  
  HoudiniApi::GetPartInfoFuncPtr
  HoudiniApi::GetPartInfo = &HoudiniApi::GetPartInfoEmptyStub;
  
  HoudiniApi::GetEdgeCountOfEdgeGroupFuncPtr
  HoudiniApi::GetEdgeCountOfEdgeGroup = &HoudiniApi::GetEdgeCountOfEdgeGroupEmptyStub;
  
  HoudiniApi::GetFaceCountsFuncPtr
  HoudiniApi::GetFaceCounts = &HoudiniApi::GetFaceCountsEmptyStub;
  
  HoudiniApi::GetVertexListFuncPtr
  HoudiniApi::GetVertexList = &HoudiniApi::GetVertexListEmptyStub;
  
  HoudiniApi::GetAttributeInfoFuncPtr
  HoudiniApi::GetAttributeInfo = &HoudiniApi::GetAttributeInfoEmptyStub;
  
  HoudiniApi::GetAttributeNamesFuncPtr
  HoudiniApi::GetAttributeNames = &HoudiniApi::GetAttributeNamesEmptyStub;
  
  HoudiniApi::GetAttributeIntDataFuncPtr
  HoudiniApi::GetAttributeIntData = &HoudiniApi::GetAttributeIntDataEmptyStub;
  
  HoudiniApi::GetAttributeIntArrayDataFuncPtr
  HoudiniApi::GetAttributeIntArrayData = &HoudiniApi::GetAttributeIntArrayDataEmptyStub;
  
  HoudiniApi::GetAttributeUInt8DataFuncPtr
  HoudiniApi::GetAttributeUInt8Data = &HoudiniApi::GetAttributeUInt8DataEmptyStub;
  
  HoudiniApi::GetAttributeUInt8ArrayDataFuncPtr
  HoudiniApi::GetAttributeUInt8ArrayData = &HoudiniApi::GetAttributeUInt8ArrayDataEmptyStub;
  
  HoudiniApi::GetAttributeInt8DataFuncPtr
  HoudiniApi::GetAttributeInt8Data = &HoudiniApi::GetAttributeInt8DataEmptyStub;
  
  HoudiniApi::GetAttributeInt8ArrayDataFuncPtr
  HoudiniApi::GetAttributeInt8ArrayData = &HoudiniApi::GetAttributeInt8ArrayDataEmptyStub;
  
  HoudiniApi::GetAttributeInt16DataFuncPtr
  HoudiniApi::GetAttributeInt16Data = &HoudiniApi::GetAttributeInt16DataEmptyStub;
  
  HoudiniApi::GetAttributeInt16ArrayDataFuncPtr
  HoudiniApi::GetAttributeInt16ArrayData = &HoudiniApi::GetAttributeInt16ArrayDataEmptyStub;
  
  HoudiniApi::GetAttributeInt64DataFuncPtr
  HoudiniApi::GetAttributeInt64Data = &HoudiniApi::GetAttributeInt64DataEmptyStub;
  
  HoudiniApi::GetAttributeInt64ArrayDataFuncPtr
  HoudiniApi::GetAttributeInt64ArrayData = &HoudiniApi::GetAttributeInt64ArrayDataEmptyStub;
  
  HoudiniApi::GetAttributeFloatDataFuncPtr
  HoudiniApi::GetAttributeFloatData = &HoudiniApi::GetAttributeFloatDataEmptyStub;
  
  HoudiniApi::GetAttributeFloatArrayDataFuncPtr
  HoudiniApi::GetAttributeFloatArrayData = &HoudiniApi::GetAttributeFloatArrayDataEmptyStub;
  
  HoudiniApi::GetAttributeFloat64DataFuncPtr
  HoudiniApi::GetAttributeFloat64Data = &HoudiniApi::GetAttributeFloat64DataEmptyStub;
  
  HoudiniApi::GetAttributeFloat64ArrayDataFuncPtr
  HoudiniApi::GetAttributeFloat64ArrayData = &HoudiniApi::GetAttributeFloat64ArrayDataEmptyStub;
  
  HoudiniApi::GetAttributeStringDataFuncPtr
  HoudiniApi::GetAttributeStringData = &HoudiniApi::GetAttributeStringDataEmptyStub;
  
  HoudiniApi::GetAttributeStringArrayDataFuncPtr
  HoudiniApi::GetAttributeStringArrayData = &HoudiniApi::GetAttributeStringArrayDataEmptyStub;
  
  HoudiniApi::GetAttributeDictionaryDataFuncPtr
  HoudiniApi::GetAttributeDictionaryData = &HoudiniApi::GetAttributeDictionaryDataEmptyStub;
  
  HoudiniApi::GetAttributeDictionaryArrayDataFuncPtr
  HoudiniApi::GetAttributeDictionaryArrayData = &HoudiniApi::GetAttributeDictionaryArrayDataEmptyStub;
  
  HoudiniApi::GetAttributeIntDataAsyncFuncPtr
  HoudiniApi::GetAttributeIntDataAsync = &HoudiniApi::GetAttributeIntDataAsyncEmptyStub;
  
  HoudiniApi::GetAttributeUInt8DataAsyncFuncPtr
  HoudiniApi::GetAttributeUInt8DataAsync = &HoudiniApi::GetAttributeUInt8DataAsyncEmptyStub;
  
  HoudiniApi::GetAttributeInt8DataAsyncFuncPtr
  HoudiniApi::GetAttributeInt8DataAsync = &HoudiniApi::GetAttributeInt8DataAsyncEmptyStub;
  
  HoudiniApi::GetAttributeInt16DataAsyncFuncPtr
  HoudiniApi::GetAttributeInt16DataAsync = &HoudiniApi::GetAttributeInt16DataAsyncEmptyStub;
  
  HoudiniApi::GetAttributeInt64DataAsyncFuncPtr
  HoudiniApi::GetAttributeInt64DataAsync = &HoudiniApi::GetAttributeInt64DataAsyncEmptyStub;
  
  HoudiniApi::GetAttributeFloatDataAsyncFuncPtr
  HoudiniApi::GetAttributeFloatDataAsync = &HoudiniApi::GetAttributeFloatDataAsyncEmptyStub;
  
  HoudiniApi::GetAttributeFloat64DataAsyncFuncPtr
  HoudiniApi::GetAttributeFloat64DataAsync = &HoudiniApi::GetAttributeFloat64DataAsyncEmptyStub;
  
  HoudiniApi::GetAttributeStringDataAsyncFuncPtr
  HoudiniApi::GetAttributeStringDataAsync = &HoudiniApi::GetAttributeStringDataAsyncEmptyStub;
  
  HoudiniApi::GetAttributeDictionaryDataAsyncFuncPtr
  HoudiniApi::GetAttributeDictionaryDataAsync = &HoudiniApi::GetAttributeDictionaryDataAsyncEmptyStub;
  
  HoudiniApi::GetAttributeIntArrayDataAsyncFuncPtr
  HoudiniApi::GetAttributeIntArrayDataAsync = &HoudiniApi::GetAttributeIntArrayDataAsyncEmptyStub;
  
  HoudiniApi::GetAttributeUInt8ArrayDataAsyncFuncPtr
  HoudiniApi::GetAttributeUInt8ArrayDataAsync = &HoudiniApi::GetAttributeUInt8ArrayDataAsyncEmptyStub;
  
  HoudiniApi::GetAttributeInt8ArrayDataAsyncFuncPtr
  HoudiniApi::GetAttributeInt8ArrayDataAsync = &HoudiniApi::GetAttributeInt8ArrayDataAsyncEmptyStub;
  
  HoudiniApi::GetAttributeInt16ArrayDataAsyncFuncPtr
  HoudiniApi::GetAttributeInt16ArrayDataAsync = &HoudiniApi::GetAttributeInt16ArrayDataAsyncEmptyStub;
  
  HoudiniApi::GetAttributeInt64ArrayDataAsyncFuncPtr
  HoudiniApi::GetAttributeInt64ArrayDataAsync = &HoudiniApi::GetAttributeInt64ArrayDataAsyncEmptyStub;
  
  HoudiniApi::GetAttributeFloatArrayDataAsyncFuncPtr
  HoudiniApi::GetAttributeFloatArrayDataAsync = &HoudiniApi::GetAttributeFloatArrayDataAsyncEmptyStub;
  
  HoudiniApi::GetAttributeFloat64ArrayDataAsyncFuncPtr
  HoudiniApi::GetAttributeFloat64ArrayDataAsync = &HoudiniApi::GetAttributeFloat64ArrayDataAsyncEmptyStub;
  
  HoudiniApi::GetAttributeStringArrayDataAsyncFuncPtr
  HoudiniApi::GetAttributeStringArrayDataAsync = &HoudiniApi::GetAttributeStringArrayDataAsyncEmptyStub;
  
  HoudiniApi::GetAttributeDictionaryArrayDataAsyncFuncPtr
  HoudiniApi::GetAttributeDictionaryArrayDataAsync = &HoudiniApi::GetAttributeDictionaryArrayDataAsyncEmptyStub;
  
  HoudiniApi::GetJobStatusFuncPtr
  HoudiniApi::GetJobStatus = &HoudiniApi::GetJobStatusEmptyStub;
  
  HoudiniApi::GetGroupNamesFuncPtr
  HoudiniApi::GetGroupNames = &HoudiniApi::GetGroupNamesEmptyStub;
  
  HoudiniApi::GetGroupMembershipFuncPtr
  HoudiniApi::GetGroupMembership = &HoudiniApi::GetGroupMembershipEmptyStub;
  
  HoudiniApi::GetGroupCountOnPackedInstancePartFuncPtr
  HoudiniApi::GetGroupCountOnPackedInstancePart = &HoudiniApi::GetGroupCountOnPackedInstancePartEmptyStub;
  
  HoudiniApi::GetGroupNamesOnPackedInstancePartFuncPtr
  HoudiniApi::GetGroupNamesOnPackedInstancePart = &HoudiniApi::GetGroupNamesOnPackedInstancePartEmptyStub;
  
  HoudiniApi::GetGroupMembershipOnPackedInstancePartFuncPtr
  HoudiniApi::GetGroupMembershipOnPackedInstancePart = &HoudiniApi::GetGroupMembershipOnPackedInstancePartEmptyStub;
  
  HoudiniApi::GetInstancedPartIdsFuncPtr
  HoudiniApi::GetInstancedPartIds = &HoudiniApi::GetInstancedPartIdsEmptyStub;
  
  HoudiniApi::GetInstancerPartTransformsFuncPtr
  HoudiniApi::GetInstancerPartTransforms = &HoudiniApi::GetInstancerPartTransformsEmptyStub;
  
  HoudiniApi::SetPartInfoFuncPtr
  HoudiniApi::SetPartInfo = &HoudiniApi::SetPartInfoEmptyStub;
  
  HoudiniApi::SetFaceCountsFuncPtr
  HoudiniApi::SetFaceCounts = &HoudiniApi::SetFaceCountsEmptyStub;
  
  HoudiniApi::SetVertexListFuncPtr
  HoudiniApi::SetVertexList = &HoudiniApi::SetVertexListEmptyStub;
  
  HoudiniApi::AddAttributeFuncPtr
  HoudiniApi::AddAttribute = &HoudiniApi::AddAttributeEmptyStub;
  
  HoudiniApi::DeleteAttributeFuncPtr
  HoudiniApi::DeleteAttribute = &HoudiniApi::DeleteAttributeEmptyStub;
  
  HoudiniApi::SetAttributeIntDataFuncPtr
  HoudiniApi::SetAttributeIntData = &HoudiniApi::SetAttributeIntDataEmptyStub;
  
  HoudiniApi::SetAttributeUInt8DataFuncPtr
  HoudiniApi::SetAttributeUInt8Data = &HoudiniApi::SetAttributeUInt8DataEmptyStub;
  
  HoudiniApi::SetAttributeInt8DataFuncPtr
  HoudiniApi::SetAttributeInt8Data = &HoudiniApi::SetAttributeInt8DataEmptyStub;
  
  HoudiniApi::SetAttributeInt16DataFuncPtr
  HoudiniApi::SetAttributeInt16Data = &HoudiniApi::SetAttributeInt16DataEmptyStub;
  
  HoudiniApi::SetAttributeInt64DataFuncPtr
  HoudiniApi::SetAttributeInt64Data = &HoudiniApi::SetAttributeInt64DataEmptyStub;
  
  HoudiniApi::SetAttributeFloatDataFuncPtr
  HoudiniApi::SetAttributeFloatData = &HoudiniApi::SetAttributeFloatDataEmptyStub;
  
  HoudiniApi::SetAttributeFloat64DataFuncPtr
  HoudiniApi::SetAttributeFloat64Data = &HoudiniApi::SetAttributeFloat64DataEmptyStub;
  
  HoudiniApi::SetAttributeStringDataFuncPtr
  HoudiniApi::SetAttributeStringData = &HoudiniApi::SetAttributeStringDataEmptyStub;
  
  HoudiniApi::SetAttributeIndexedStringDataFuncPtr
  HoudiniApi::SetAttributeIndexedStringData = &HoudiniApi::SetAttributeIndexedStringDataEmptyStub;
  
  HoudiniApi::SetAttributeStringUniqueDataFuncPtr
  HoudiniApi::SetAttributeStringUniqueData = &HoudiniApi::SetAttributeStringUniqueDataEmptyStub;
  
  HoudiniApi::SetAttributeIntUniqueDataFuncPtr
  HoudiniApi::SetAttributeIntUniqueData = &HoudiniApi::SetAttributeIntUniqueDataEmptyStub;
  
  HoudiniApi::SetAttributeUInt8UniqueDataFuncPtr
  HoudiniApi::SetAttributeUInt8UniqueData = &HoudiniApi::SetAttributeUInt8UniqueDataEmptyStub;
  
  HoudiniApi::SetAttributeInt8UniqueDataFuncPtr
  HoudiniApi::SetAttributeInt8UniqueData = &HoudiniApi::SetAttributeInt8UniqueDataEmptyStub;
  
  HoudiniApi::SetAttributeInt16UniqueDataFuncPtr
  HoudiniApi::SetAttributeInt16UniqueData = &HoudiniApi::SetAttributeInt16UniqueDataEmptyStub;
  
  HoudiniApi::SetAttributeInt64UniqueDataFuncPtr
  HoudiniApi::SetAttributeInt64UniqueData = &HoudiniApi::SetAttributeInt64UniqueDataEmptyStub;
  
  HoudiniApi::SetAttributeFloatUniqueDataFuncPtr
  HoudiniApi::SetAttributeFloatUniqueData = &HoudiniApi::SetAttributeFloatUniqueDataEmptyStub;
  
  HoudiniApi::SetAttributeFloat64UniqueDataFuncPtr
  HoudiniApi::SetAttributeFloat64UniqueData = &HoudiniApi::SetAttributeFloat64UniqueDataEmptyStub;
  
  HoudiniApi::SetAttributeDictionaryDataFuncPtr
  HoudiniApi::SetAttributeDictionaryData = &HoudiniApi::SetAttributeDictionaryDataEmptyStub;
  
  HoudiniApi::SetAttributeIntArrayDataFuncPtr
  HoudiniApi::SetAttributeIntArrayData = &HoudiniApi::SetAttributeIntArrayDataEmptyStub;
  
  HoudiniApi::SetAttributeUInt8ArrayDataFuncPtr
  HoudiniApi::SetAttributeUInt8ArrayData = &HoudiniApi::SetAttributeUInt8ArrayDataEmptyStub;
  
  HoudiniApi::SetAttributeInt8ArrayDataFuncPtr
  HoudiniApi::SetAttributeInt8ArrayData = &HoudiniApi::SetAttributeInt8ArrayDataEmptyStub;
  
  HoudiniApi::SetAttributeInt16ArrayDataFuncPtr
  HoudiniApi::SetAttributeInt16ArrayData = &HoudiniApi::SetAttributeInt16ArrayDataEmptyStub;
  
  HoudiniApi::SetAttributeInt64ArrayDataFuncPtr
  HoudiniApi::SetAttributeInt64ArrayData = &HoudiniApi::SetAttributeInt64ArrayDataEmptyStub;
  
  HoudiniApi::SetAttributeFloatArrayDataFuncPtr
  HoudiniApi::SetAttributeFloatArrayData = &HoudiniApi::SetAttributeFloatArrayDataEmptyStub;
  
  HoudiniApi::SetAttributeFloat64ArrayDataFuncPtr
  HoudiniApi::SetAttributeFloat64ArrayData = &HoudiniApi::SetAttributeFloat64ArrayDataEmptyStub;
  
  HoudiniApi::SetAttributeStringArrayDataFuncPtr
  HoudiniApi::SetAttributeStringArrayData = &HoudiniApi::SetAttributeStringArrayDataEmptyStub;
  
  HoudiniApi::SetAttributeDictionaryArrayDataFuncPtr
  HoudiniApi::SetAttributeDictionaryArrayData = &HoudiniApi::SetAttributeDictionaryArrayDataEmptyStub;
  
  HoudiniApi::SetAttributeIntDataAsyncFuncPtr
  HoudiniApi::SetAttributeIntDataAsync = &HoudiniApi::SetAttributeIntDataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeUInt8DataAsyncFuncPtr
  HoudiniApi::SetAttributeUInt8DataAsync = &HoudiniApi::SetAttributeUInt8DataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeInt8DataAsyncFuncPtr
  HoudiniApi::SetAttributeInt8DataAsync = &HoudiniApi::SetAttributeInt8DataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeInt16DataAsyncFuncPtr
  HoudiniApi::SetAttributeInt16DataAsync = &HoudiniApi::SetAttributeInt16DataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeInt64DataAsyncFuncPtr
  HoudiniApi::SetAttributeInt64DataAsync = &HoudiniApi::SetAttributeInt64DataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeFloatDataAsyncFuncPtr
  HoudiniApi::SetAttributeFloatDataAsync = &HoudiniApi::SetAttributeFloatDataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeFloat64DataAsyncFuncPtr
  HoudiniApi::SetAttributeFloat64DataAsync = &HoudiniApi::SetAttributeFloat64DataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeStringDataAsyncFuncPtr
  HoudiniApi::SetAttributeStringDataAsync = &HoudiniApi::SetAttributeStringDataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeIndexedStringDataAsyncFuncPtr
  HoudiniApi::SetAttributeIndexedStringDataAsync = &HoudiniApi::SetAttributeIndexedStringDataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeStringUniqueDataAsyncFuncPtr
  HoudiniApi::SetAttributeStringUniqueDataAsync = &HoudiniApi::SetAttributeStringUniqueDataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeIntUniqueDataAsyncFuncPtr
  HoudiniApi::SetAttributeIntUniqueDataAsync = &HoudiniApi::SetAttributeIntUniqueDataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeUInt8UniqueDataAsyncFuncPtr
  HoudiniApi::SetAttributeUInt8UniqueDataAsync = &HoudiniApi::SetAttributeUInt8UniqueDataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeInt8UniqueDataAsyncFuncPtr
  HoudiniApi::SetAttributeInt8UniqueDataAsync = &HoudiniApi::SetAttributeInt8UniqueDataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeInt16UniqueDataAsyncFuncPtr
  HoudiniApi::SetAttributeInt16UniqueDataAsync = &HoudiniApi::SetAttributeInt16UniqueDataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeInt64UniqueDataAsyncFuncPtr
  HoudiniApi::SetAttributeInt64UniqueDataAsync = &HoudiniApi::SetAttributeInt64UniqueDataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeFloatUniqueDataAsyncFuncPtr
  HoudiniApi::SetAttributeFloatUniqueDataAsync = &HoudiniApi::SetAttributeFloatUniqueDataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeFloat64UniqueDataAsyncFuncPtr
  HoudiniApi::SetAttributeFloat64UniqueDataAsync = &HoudiniApi::SetAttributeFloat64UniqueDataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeDictionaryDataAsyncFuncPtr
  HoudiniApi::SetAttributeDictionaryDataAsync = &HoudiniApi::SetAttributeDictionaryDataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeIntArrayDataAsyncFuncPtr
  HoudiniApi::SetAttributeIntArrayDataAsync = &HoudiniApi::SetAttributeIntArrayDataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeUInt8ArrayDataAsyncFuncPtr
  HoudiniApi::SetAttributeUInt8ArrayDataAsync = &HoudiniApi::SetAttributeUInt8ArrayDataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeInt8ArrayDataAsyncFuncPtr
  HoudiniApi::SetAttributeInt8ArrayDataAsync = &HoudiniApi::SetAttributeInt8ArrayDataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeInt16ArrayDataAsyncFuncPtr
  HoudiniApi::SetAttributeInt16ArrayDataAsync = &HoudiniApi::SetAttributeInt16ArrayDataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeInt64ArrayDataAsyncFuncPtr
  HoudiniApi::SetAttributeInt64ArrayDataAsync = &HoudiniApi::SetAttributeInt64ArrayDataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeFloatArrayDataAsyncFuncPtr
  HoudiniApi::SetAttributeFloatArrayDataAsync = &HoudiniApi::SetAttributeFloatArrayDataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeFloat64ArrayDataAsyncFuncPtr
  HoudiniApi::SetAttributeFloat64ArrayDataAsync = &HoudiniApi::SetAttributeFloat64ArrayDataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeStringArrayDataAsyncFuncPtr
  HoudiniApi::SetAttributeStringArrayDataAsync = &HoudiniApi::SetAttributeStringArrayDataAsyncEmptyStub;
  
  HoudiniApi::SetAttributeDictionaryArrayDataAsyncFuncPtr
  HoudiniApi::SetAttributeDictionaryArrayDataAsync = &HoudiniApi::SetAttributeDictionaryArrayDataAsyncEmptyStub;
  
  HoudiniApi::AddGroupFuncPtr
  HoudiniApi::AddGroup = &HoudiniApi::AddGroupEmptyStub;
  
  HoudiniApi::DeleteGroupFuncPtr
  HoudiniApi::DeleteGroup = &HoudiniApi::DeleteGroupEmptyStub;
  
  HoudiniApi::SetGroupMembershipFuncPtr
  HoudiniApi::SetGroupMembership = &HoudiniApi::SetGroupMembershipEmptyStub;
  
  HoudiniApi::CommitGeoFuncPtr
  HoudiniApi::CommitGeo = &HoudiniApi::CommitGeoEmptyStub;
  
  HoudiniApi::RevertGeoFuncPtr
  HoudiniApi::RevertGeo = &HoudiniApi::RevertGeoEmptyStub;
  
  HoudiniApi::GetMaterialNodeIdsOnFacesFuncPtr
  HoudiniApi::GetMaterialNodeIdsOnFaces = &HoudiniApi::GetMaterialNodeIdsOnFacesEmptyStub;
  
  HoudiniApi::GetMaterialInfoFuncPtr
  HoudiniApi::GetMaterialInfo = &HoudiniApi::GetMaterialInfoEmptyStub;
  
  HoudiniApi::RenderCOPToImageFuncPtr
  HoudiniApi::RenderCOPToImage = &HoudiniApi::RenderCOPToImageEmptyStub;
  
  HoudiniApi::RenderTextureToImageFuncPtr
  HoudiniApi::RenderTextureToImage = &HoudiniApi::RenderTextureToImageEmptyStub;
  
  HoudiniApi::GetImageInfoFuncPtr
  HoudiniApi::GetImageInfo = &HoudiniApi::GetImageInfoEmptyStub;
  
  HoudiniApi::SetImageInfoFuncPtr
  HoudiniApi::SetImageInfo = &HoudiniApi::SetImageInfoEmptyStub;
  
  HoudiniApi::GetImagePlaneCountFuncPtr
  HoudiniApi::GetImagePlaneCount = &HoudiniApi::GetImagePlaneCountEmptyStub;
  
  HoudiniApi::GetImagePlanesFuncPtr
  HoudiniApi::GetImagePlanes = &HoudiniApi::GetImagePlanesEmptyStub;
  
  HoudiniApi::ExtractImageToFileFuncPtr
  HoudiniApi::ExtractImageToFile = &HoudiniApi::ExtractImageToFileEmptyStub;
  
  HoudiniApi::GetImageFilePathFuncPtr
  HoudiniApi::GetImageFilePath = &HoudiniApi::GetImageFilePathEmptyStub;
  
  HoudiniApi::ExtractImageToMemoryFuncPtr
  HoudiniApi::ExtractImageToMemory = &HoudiniApi::ExtractImageToMemoryEmptyStub;
  
  HoudiniApi::GetImageMemoryBufferFuncPtr
  HoudiniApi::GetImageMemoryBuffer = &HoudiniApi::GetImageMemoryBufferEmptyStub;
  
  HoudiniApi::GetSupportedImageFileFormatCountFuncPtr
  HoudiniApi::GetSupportedImageFileFormatCount = &HoudiniApi::GetSupportedImageFileFormatCountEmptyStub;
  
  HoudiniApi::GetSupportedImageFileFormatsFuncPtr
  HoudiniApi::GetSupportedImageFileFormats = &HoudiniApi::GetSupportedImageFileFormatsEmptyStub;
  
  HoudiniApi::SetAnimCurveFuncPtr
  HoudiniApi::SetAnimCurve = &HoudiniApi::SetAnimCurveEmptyStub;
  
  HoudiniApi::SetTransformAnimCurveFuncPtr
  HoudiniApi::SetTransformAnimCurve = &HoudiniApi::SetTransformAnimCurveEmptyStub;
  
  HoudiniApi::ResetSimulationFuncPtr
  HoudiniApi::ResetSimulation = &HoudiniApi::ResetSimulationEmptyStub;
  
  HoudiniApi::GetVolumeInfoFuncPtr
  HoudiniApi::GetVolumeInfo = &HoudiniApi::GetVolumeInfoEmptyStub;
  
  HoudiniApi::GetFirstVolumeTileFuncPtr
  HoudiniApi::GetFirstVolumeTile = &HoudiniApi::GetFirstVolumeTileEmptyStub;
  
  HoudiniApi::GetNextVolumeTileFuncPtr
  HoudiniApi::GetNextVolumeTile = &HoudiniApi::GetNextVolumeTileEmptyStub;
  
  HoudiniApi::GetVolumeVoxelFloatDataFuncPtr
  HoudiniApi::GetVolumeVoxelFloatData = &HoudiniApi::GetVolumeVoxelFloatDataEmptyStub;
  
  HoudiniApi::GetVolumeTileFloatDataFuncPtr
  HoudiniApi::GetVolumeTileFloatData = &HoudiniApi::GetVolumeTileFloatDataEmptyStub;
  
  HoudiniApi::GetVolumeVoxelIntDataFuncPtr
  HoudiniApi::GetVolumeVoxelIntData = &HoudiniApi::GetVolumeVoxelIntDataEmptyStub;
  
  HoudiniApi::GetVolumeTileIntDataFuncPtr
  HoudiniApi::GetVolumeTileIntData = &HoudiniApi::GetVolumeTileIntDataEmptyStub;
  
  HoudiniApi::GetHeightFieldDataFuncPtr
  HoudiniApi::GetHeightFieldData = &HoudiniApi::GetHeightFieldDataEmptyStub;
  
  HoudiniApi::SetVolumeInfoFuncPtr
  HoudiniApi::SetVolumeInfo = &HoudiniApi::SetVolumeInfoEmptyStub;
  
  HoudiniApi::SetVolumeTileFloatDataFuncPtr
  HoudiniApi::SetVolumeTileFloatData = &HoudiniApi::SetVolumeTileFloatDataEmptyStub;
  
  HoudiniApi::SetVolumeTileIntDataFuncPtr
  HoudiniApi::SetVolumeTileIntData = &HoudiniApi::SetVolumeTileIntDataEmptyStub;
  
  HoudiniApi::SetVolumeVoxelFloatDataFuncPtr
  HoudiniApi::SetVolumeVoxelFloatData = &HoudiniApi::SetVolumeVoxelFloatDataEmptyStub;
  
  HoudiniApi::SetVolumeVoxelIntDataFuncPtr
  HoudiniApi::SetVolumeVoxelIntData = &HoudiniApi::SetVolumeVoxelIntDataEmptyStub;
  
  HoudiniApi::GetVolumeBoundsFuncPtr
  HoudiniApi::GetVolumeBounds = &HoudiniApi::GetVolumeBoundsEmptyStub;
  
  HoudiniApi::SetHeightFieldDataFuncPtr
  HoudiniApi::SetHeightFieldData = &HoudiniApi::SetHeightFieldDataEmptyStub;
  
  HoudiniApi::GetVolumeVisualInfoFuncPtr
  HoudiniApi::GetVolumeVisualInfo = &HoudiniApi::GetVolumeVisualInfoEmptyStub;
  
  HoudiniApi::GetCurveInfoFuncPtr
  HoudiniApi::GetCurveInfo = &HoudiniApi::GetCurveInfoEmptyStub;
  
  HoudiniApi::GetCurveCountsFuncPtr
  HoudiniApi::GetCurveCounts = &HoudiniApi::GetCurveCountsEmptyStub;
  
  HoudiniApi::GetCurveOrdersFuncPtr
  HoudiniApi::GetCurveOrders = &HoudiniApi::GetCurveOrdersEmptyStub;
  
  HoudiniApi::GetCurveKnotsFuncPtr
  HoudiniApi::GetCurveKnots = &HoudiniApi::GetCurveKnotsEmptyStub;
  
  HoudiniApi::SetCurveInfoFuncPtr
  HoudiniApi::SetCurveInfo = &HoudiniApi::SetCurveInfoEmptyStub;
  
  HoudiniApi::SetCurveCountsFuncPtr
  HoudiniApi::SetCurveCounts = &HoudiniApi::SetCurveCountsEmptyStub;
  
  HoudiniApi::SetCurveOrdersFuncPtr
  HoudiniApi::SetCurveOrders = &HoudiniApi::SetCurveOrdersEmptyStub;
  
  HoudiniApi::SetCurveKnotsFuncPtr
  HoudiniApi::SetCurveKnots = &HoudiniApi::SetCurveKnotsEmptyStub;
  
  HoudiniApi::GetInputCurveInfoFuncPtr
  HoudiniApi::GetInputCurveInfo = &HoudiniApi::GetInputCurveInfoEmptyStub;
  
  HoudiniApi::SetInputCurveInfoFuncPtr
  HoudiniApi::SetInputCurveInfo = &HoudiniApi::SetInputCurveInfoEmptyStub;
  
  HoudiniApi::SetInputCurvePositionsFuncPtr
  HoudiniApi::SetInputCurvePositions = &HoudiniApi::SetInputCurvePositionsEmptyStub;
  
  HoudiniApi::SetInputCurvePositionsRotationsScalesFuncPtr
  HoudiniApi::SetInputCurvePositionsRotationsScales = &HoudiniApi::SetInputCurvePositionsRotationsScalesEmptyStub;
  
  HoudiniApi::GetBoxInfoFuncPtr
  HoudiniApi::GetBoxInfo = &HoudiniApi::GetBoxInfoEmptyStub;
  
  HoudiniApi::GetSphereInfoFuncPtr
  HoudiniApi::GetSphereInfo = &HoudiniApi::GetSphereInfoEmptyStub;
  
  HoudiniApi::GetActiveCacheCountFuncPtr
  HoudiniApi::GetActiveCacheCount = &HoudiniApi::GetActiveCacheCountEmptyStub;
  
  HoudiniApi::GetActiveCacheNamesFuncPtr
  HoudiniApi::GetActiveCacheNames = &HoudiniApi::GetActiveCacheNamesEmptyStub;
  
  HoudiniApi::GetCachePropertyFuncPtr
  HoudiniApi::GetCacheProperty = &HoudiniApi::GetCachePropertyEmptyStub;
  
  HoudiniApi::SetCachePropertyFuncPtr
  HoudiniApi::SetCacheProperty = &HoudiniApi::SetCachePropertyEmptyStub;
  
  HoudiniApi::SaveGeoToFileFuncPtr
  HoudiniApi::SaveGeoToFile = &HoudiniApi::SaveGeoToFileEmptyStub;
  
  HoudiniApi::LoadGeoFromFileFuncPtr
  HoudiniApi::LoadGeoFromFile = &HoudiniApi::LoadGeoFromFileEmptyStub;
  
  HoudiniApi::SaveNodeToFileFuncPtr
  HoudiniApi::SaveNodeToFile = &HoudiniApi::SaveNodeToFileEmptyStub;
  
  HoudiniApi::LoadNodeFromFileFuncPtr
  HoudiniApi::LoadNodeFromFile = &HoudiniApi::LoadNodeFromFileEmptyStub;
  
  HoudiniApi::GetGeoSizeFuncPtr
  HoudiniApi::GetGeoSize = &HoudiniApi::GetGeoSizeEmptyStub;
  
  HoudiniApi::SaveGeoToMemoryFuncPtr
  HoudiniApi::SaveGeoToMemory = &HoudiniApi::SaveGeoToMemoryEmptyStub;
  
  HoudiniApi::LoadGeoFromMemoryFuncPtr
  HoudiniApi::LoadGeoFromMemory = &HoudiniApi::LoadGeoFromMemoryEmptyStub;
  
  HoudiniApi::SetNodeDisplayFuncPtr
  HoudiniApi::SetNodeDisplay = &HoudiniApi::SetNodeDisplayEmptyStub;
  
  HoudiniApi::GetTotalCookCountFuncPtr
  HoudiniApi::GetTotalCookCount = &HoudiniApi::GetTotalCookCountEmptyStub;
  
  HoudiniApi::SetSessionSyncFuncPtr
  HoudiniApi::SetSessionSync = &HoudiniApi::SetSessionSyncEmptyStub;
  
  HoudiniApi::GetViewportFuncPtr
  HoudiniApi::GetViewport = &HoudiniApi::GetViewportEmptyStub;
  
  HoudiniApi::SetViewportFuncPtr
  HoudiniApi::SetViewport = &HoudiniApi::SetViewportEmptyStub;
  
  HoudiniApi::GetSessionSyncInfoFuncPtr
  HoudiniApi::GetSessionSyncInfo = &HoudiniApi::GetSessionSyncInfoEmptyStub;
  
  HoudiniApi::SetSessionSyncInfoFuncPtr
  HoudiniApi::SetSessionSyncInfo = &HoudiniApi::SetSessionSyncInfoEmptyStub;
  
  HoudiniApi::GetPDGGraphContextsFuncPtr
  HoudiniApi::GetPDGGraphContexts = &HoudiniApi::GetPDGGraphContextsEmptyStub;
  
  HoudiniApi::GetPDGGraphContextsCountFuncPtr
  HoudiniApi::GetPDGGraphContextsCount = &HoudiniApi::GetPDGGraphContextsCountEmptyStub;
  
  HoudiniApi::GetPDGGraphContextIdFuncPtr
  HoudiniApi::GetPDGGraphContextId = &HoudiniApi::GetPDGGraphContextIdEmptyStub;
  
  HoudiniApi::CookPDGFuncPtr
  HoudiniApi::CookPDG = &HoudiniApi::CookPDGEmptyStub;
  
  HoudiniApi::CookPDGAllOutputsFuncPtr
  HoudiniApi::CookPDGAllOutputs = &HoudiniApi::CookPDGAllOutputsEmptyStub;
  
  HoudiniApi::GetPDGEventsFuncPtr
  HoudiniApi::GetPDGEvents = &HoudiniApi::GetPDGEventsEmptyStub;
  
  HoudiniApi::GetPDGStateFuncPtr
  HoudiniApi::GetPDGState = &HoudiniApi::GetPDGStateEmptyStub;
  
  HoudiniApi::CreateWorkItemFuncPtr
  HoudiniApi::CreateWorkItem = &HoudiniApi::CreateWorkItemEmptyStub;
  
  HoudiniApi::GetWorkItemInfoFuncPtr
  HoudiniApi::GetWorkItemInfo = &HoudiniApi::GetWorkItemInfoEmptyStub;
  
  HoudiniApi::SetWorkItemIntAttributeFuncPtr
  HoudiniApi::SetWorkItemIntAttribute = &HoudiniApi::SetWorkItemIntAttributeEmptyStub;
  
  HoudiniApi::SetWorkItemFloatAttributeFuncPtr
  HoudiniApi::SetWorkItemFloatAttribute = &HoudiniApi::SetWorkItemFloatAttributeEmptyStub;
  
  HoudiniApi::SetWorkItemStringAttributeFuncPtr
  HoudiniApi::SetWorkItemStringAttribute = &HoudiniApi::SetWorkItemStringAttributeEmptyStub;
  
  HoudiniApi::CommitWorkItemsFuncPtr
  HoudiniApi::CommitWorkItems = &HoudiniApi::CommitWorkItemsEmptyStub;
  
  HoudiniApi::GetNumWorkItemsFuncPtr
  HoudiniApi::GetNumWorkItems = &HoudiniApi::GetNumWorkItemsEmptyStub;
  
  HoudiniApi::GetWorkItemsFuncPtr
  HoudiniApi::GetWorkItems = &HoudiniApi::GetWorkItemsEmptyStub;
  
  HoudiniApi::GetWorkItemAttributeSizeFuncPtr
  HoudiniApi::GetWorkItemAttributeSize = &HoudiniApi::GetWorkItemAttributeSizeEmptyStub;
  
  HoudiniApi::GetWorkItemIntAttributeFuncPtr
  HoudiniApi::GetWorkItemIntAttribute = &HoudiniApi::GetWorkItemIntAttributeEmptyStub;
  
  HoudiniApi::GetWorkItemFloatAttributeFuncPtr
  HoudiniApi::GetWorkItemFloatAttribute = &HoudiniApi::GetWorkItemFloatAttributeEmptyStub;
  
  HoudiniApi::GetWorkItemStringAttributeFuncPtr
  HoudiniApi::GetWorkItemStringAttribute = &HoudiniApi::GetWorkItemStringAttributeEmptyStub;
  
  HoudiniApi::GetWorkItemOutputFilesFuncPtr
  HoudiniApi::GetWorkItemOutputFiles = &HoudiniApi::GetWorkItemOutputFilesEmptyStub;
  
  HoudiniApi::DirtyPDGNodeFuncPtr
  HoudiniApi::DirtyPDGNode = &HoudiniApi::DirtyPDGNodeEmptyStub;
  
  HoudiniApi::PausePDGCookFuncPtr
  HoudiniApi::PausePDGCook = &HoudiniApi::PausePDGCookEmptyStub;
  
  HoudiniApi::CancelPDGCookFuncPtr
  HoudiniApi::CancelPDGCook = &HoudiniApi::CancelPDGCookEmptyStub;
  
  HoudiniApi::SessionInfo_InitFuncPtr
  HoudiniApi::SessionInfo_Init = &HoudiniApi::SessionInfo_InitEmptyStub;
  
  HoudiniApi::SessionInfo_CreateFuncPtr
  HoudiniApi::SessionInfo_Create = &HoudiniApi::SessionInfo_CreateEmptyStub;
  
  HoudiniApi::ThriftServerOptions_InitFuncPtr
  HoudiniApi::ThriftServerOptions_Init = &HoudiniApi::ThriftServerOptions_InitEmptyStub;
  
  HoudiniApi::ThriftServerOptions_CreateFuncPtr
  HoudiniApi::ThriftServerOptions_Create = &HoudiniApi::ThriftServerOptions_CreateEmptyStub;
  
  HoudiniApi::TimelineOptions_InitFuncPtr
  HoudiniApi::TimelineOptions_Init = &HoudiniApi::TimelineOptions_InitEmptyStub;
  
  HoudiniApi::TimelineOptions_CreateFuncPtr
  HoudiniApi::TimelineOptions_Create = &HoudiniApi::TimelineOptions_CreateEmptyStub;
  
  HoudiniApi::CompositorOptions_InitFuncPtr
  HoudiniApi::CompositorOptions_Init = &HoudiniApi::CompositorOptions_InitEmptyStub;
  
  HoudiniApi::CompositorOptions_CreateFuncPtr
  HoudiniApi::CompositorOptions_Create = &HoudiniApi::CompositorOptions_CreateEmptyStub;
  
  HoudiniApi::AssetInfo_InitFuncPtr
  HoudiniApi::AssetInfo_Init = &HoudiniApi::AssetInfo_InitEmptyStub;
  
  HoudiniApi::AssetInfo_CreateFuncPtr
  HoudiniApi::AssetInfo_Create = &HoudiniApi::AssetInfo_CreateEmptyStub;
  
  HoudiniApi::CookOptions_InitFuncPtr
  HoudiniApi::CookOptions_Init = &HoudiniApi::CookOptions_InitEmptyStub;
  
  HoudiniApi::CookOptions_CreateFuncPtr
  HoudiniApi::CookOptions_Create = &HoudiniApi::CookOptions_CreateEmptyStub;
  
  HoudiniApi::CookOptions_AreEqualFuncPtr
  HoudiniApi::CookOptions_AreEqual = &HoudiniApi::CookOptions_AreEqualEmptyStub;
  
  HoudiniApi::NodeInfo_InitFuncPtr
  HoudiniApi::NodeInfo_Init = &HoudiniApi::NodeInfo_InitEmptyStub;
  
  HoudiniApi::NodeInfo_CreateFuncPtr
  HoudiniApi::NodeInfo_Create = &HoudiniApi::NodeInfo_CreateEmptyStub;
  
  HoudiniApi::ParmInfo_InitFuncPtr
  HoudiniApi::ParmInfo_Init = &HoudiniApi::ParmInfo_InitEmptyStub;
  
  HoudiniApi::ParmInfo_CreateFuncPtr
  HoudiniApi::ParmInfo_Create = &HoudiniApi::ParmInfo_CreateEmptyStub;
  
  HoudiniApi::ParmInfo_IsIntFuncPtr
  HoudiniApi::ParmInfo_IsInt = &HoudiniApi::ParmInfo_IsIntEmptyStub;
  
  HoudiniApi::ParmInfo_IsFloatFuncPtr
  HoudiniApi::ParmInfo_IsFloat = &HoudiniApi::ParmInfo_IsFloatEmptyStub;
  
  HoudiniApi::ParmInfo_IsStringFuncPtr
  HoudiniApi::ParmInfo_IsString = &HoudiniApi::ParmInfo_IsStringEmptyStub;
  
  HoudiniApi::ParmInfo_IsPathFuncPtr
  HoudiniApi::ParmInfo_IsPath = &HoudiniApi::ParmInfo_IsPathEmptyStub;
  
  HoudiniApi::ParmInfo_IsNodeFuncPtr
  HoudiniApi::ParmInfo_IsNode = &HoudiniApi::ParmInfo_IsNodeEmptyStub;
  
  HoudiniApi::ParmInfo_IsNonValueFuncPtr
  HoudiniApi::ParmInfo_IsNonValue = &HoudiniApi::ParmInfo_IsNonValueEmptyStub;
  
  HoudiniApi::ParmInfo_GetIntValueCountFuncPtr
  HoudiniApi::ParmInfo_GetIntValueCount = &HoudiniApi::ParmInfo_GetIntValueCountEmptyStub;
  
  HoudiniApi::ParmInfo_GetFloatValueCountFuncPtr
  HoudiniApi::ParmInfo_GetFloatValueCount = &HoudiniApi::ParmInfo_GetFloatValueCountEmptyStub;
  
  HoudiniApi::ParmInfo_GetStringValueCountFuncPtr
  HoudiniApi::ParmInfo_GetStringValueCount = &HoudiniApi::ParmInfo_GetStringValueCountEmptyStub;
  
  HoudiniApi::ParmChoiceInfo_InitFuncPtr
  HoudiniApi::ParmChoiceInfo_Init = &HoudiniApi::ParmChoiceInfo_InitEmptyStub;
  
  HoudiniApi::ParmChoiceInfo_CreateFuncPtr
  HoudiniApi::ParmChoiceInfo_Create = &HoudiniApi::ParmChoiceInfo_CreateEmptyStub;
  
  HoudiniApi::HandleInfo_InitFuncPtr
  HoudiniApi::HandleInfo_Init = &HoudiniApi::HandleInfo_InitEmptyStub;
  
  HoudiniApi::HandleInfo_CreateFuncPtr
  HoudiniApi::HandleInfo_Create = &HoudiniApi::HandleInfo_CreateEmptyStub;
  
  HoudiniApi::HandleBindingInfo_InitFuncPtr
  HoudiniApi::HandleBindingInfo_Init = &HoudiniApi::HandleBindingInfo_InitEmptyStub;
  
  HoudiniApi::HandleBindingInfo_CreateFuncPtr
  HoudiniApi::HandleBindingInfo_Create = &HoudiniApi::HandleBindingInfo_CreateEmptyStub;
  
  HoudiniApi::ObjectInfo_InitFuncPtr
  HoudiniApi::ObjectInfo_Init = &HoudiniApi::ObjectInfo_InitEmptyStub;
  
  HoudiniApi::ObjectInfo_CreateFuncPtr
  HoudiniApi::ObjectInfo_Create = &HoudiniApi::ObjectInfo_CreateEmptyStub;
  
  HoudiniApi::GeoInfo_InitFuncPtr
  HoudiniApi::GeoInfo_Init = &HoudiniApi::GeoInfo_InitEmptyStub;
  
  HoudiniApi::GeoInfo_CreateFuncPtr
  HoudiniApi::GeoInfo_Create = &HoudiniApi::GeoInfo_CreateEmptyStub;
  
  HoudiniApi::GeoInfo_GetGroupCountByTypeFuncPtr
  HoudiniApi::GeoInfo_GetGroupCountByType = &HoudiniApi::GeoInfo_GetGroupCountByTypeEmptyStub;
  
  HoudiniApi::PartInfo_InitFuncPtr
  HoudiniApi::PartInfo_Init = &HoudiniApi::PartInfo_InitEmptyStub;
  
  HoudiniApi::PartInfo_CreateFuncPtr
  HoudiniApi::PartInfo_Create = &HoudiniApi::PartInfo_CreateEmptyStub;
  
  HoudiniApi::PartInfo_GetElementCountByAttributeOwnerFuncPtr
  HoudiniApi::PartInfo_GetElementCountByAttributeOwner = &HoudiniApi::PartInfo_GetElementCountByAttributeOwnerEmptyStub;
  
  HoudiniApi::PartInfo_GetElementCountByGroupTypeFuncPtr
  HoudiniApi::PartInfo_GetElementCountByGroupType = &HoudiniApi::PartInfo_GetElementCountByGroupTypeEmptyStub;
  
  HoudiniApi::PartInfo_GetAttributeCountByOwnerFuncPtr
  HoudiniApi::PartInfo_GetAttributeCountByOwner = &HoudiniApi::PartInfo_GetAttributeCountByOwnerEmptyStub;
  
  HoudiniApi::AttributeInfo_InitFuncPtr
  HoudiniApi::AttributeInfo_Init = &HoudiniApi::AttributeInfo_InitEmptyStub;
  
  HoudiniApi::AttributeInfo_CreateFuncPtr
  HoudiniApi::AttributeInfo_Create = &HoudiniApi::AttributeInfo_CreateEmptyStub;
  
  HoudiniApi::MaterialInfo_InitFuncPtr
  HoudiniApi::MaterialInfo_Init = &HoudiniApi::MaterialInfo_InitEmptyStub;
  
  HoudiniApi::MaterialInfo_CreateFuncPtr
  HoudiniApi::MaterialInfo_Create = &HoudiniApi::MaterialInfo_CreateEmptyStub;
  
  HoudiniApi::ImageFileFormat_InitFuncPtr
  HoudiniApi::ImageFileFormat_Init = &HoudiniApi::ImageFileFormat_InitEmptyStub;
  
  HoudiniApi::ImageFileFormat_CreateFuncPtr
  HoudiniApi::ImageFileFormat_Create = &HoudiniApi::ImageFileFormat_CreateEmptyStub;
  
  HoudiniApi::ImageInfo_InitFuncPtr
  HoudiniApi::ImageInfo_Init = &HoudiniApi::ImageInfo_InitEmptyStub;
  
  HoudiniApi::ImageInfo_CreateFuncPtr
  HoudiniApi::ImageInfo_Create = &HoudiniApi::ImageInfo_CreateEmptyStub;
  
  HoudiniApi::Keyframe_InitFuncPtr
  HoudiniApi::Keyframe_Init = &HoudiniApi::Keyframe_InitEmptyStub;
  
  HoudiniApi::Keyframe_CreateFuncPtr
  HoudiniApi::Keyframe_Create = &HoudiniApi::Keyframe_CreateEmptyStub;
  
  HoudiniApi::VolumeInfo_InitFuncPtr
  HoudiniApi::VolumeInfo_Init = &HoudiniApi::VolumeInfo_InitEmptyStub;
  
  HoudiniApi::VolumeInfo_CreateFuncPtr
  HoudiniApi::VolumeInfo_Create = &HoudiniApi::VolumeInfo_CreateEmptyStub;
  
  HoudiniApi::VolumeTileInfo_InitFuncPtr
  HoudiniApi::VolumeTileInfo_Init = &HoudiniApi::VolumeTileInfo_InitEmptyStub;
  
  HoudiniApi::VolumeTileInfo_CreateFuncPtr
  HoudiniApi::VolumeTileInfo_Create = &HoudiniApi::VolumeTileInfo_CreateEmptyStub;
  
  HoudiniApi::CurveInfo_InitFuncPtr
  HoudiniApi::CurveInfo_Init = &HoudiniApi::CurveInfo_InitEmptyStub;
  
  HoudiniApi::CurveInfo_CreateFuncPtr
  HoudiniApi::CurveInfo_Create = &HoudiniApi::CurveInfo_CreateEmptyStub;
  
  HoudiniApi::InputCurveInfo_InitFuncPtr
  HoudiniApi::InputCurveInfo_Init = &HoudiniApi::InputCurveInfo_InitEmptyStub;
  
  HoudiniApi::InputCurveInfo_CreateFuncPtr
  HoudiniApi::InputCurveInfo_Create = &HoudiniApi::InputCurveInfo_CreateEmptyStub;
  
  HoudiniApi::Transform_InitFuncPtr
  HoudiniApi::Transform_Init = &HoudiniApi::Transform_InitEmptyStub;
  
  HoudiniApi::Transform_CreateFuncPtr
  HoudiniApi::Transform_Create = &HoudiniApi::Transform_CreateEmptyStub;
  
  HoudiniApi::TransformEuler_InitFuncPtr
  HoudiniApi::TransformEuler_Init = &HoudiniApi::TransformEuler_InitEmptyStub;
  
  HoudiniApi::TransformEuler_CreateFuncPtr
  HoudiniApi::TransformEuler_Create = &HoudiniApi::TransformEuler_CreateEmptyStub;
  
  HoudiniApi::Viewport_InitFuncPtr
  HoudiniApi::Viewport_Init = &HoudiniApi::Viewport_InitEmptyStub;
  
  HoudiniApi::Viewport_CreateFuncPtr
  HoudiniApi::Viewport_Create = &HoudiniApi::Viewport_CreateEmptyStub;
  
  HoudiniApi::SessionSyncInfo_InitFuncPtr
  HoudiniApi::SessionSyncInfo_Init = &HoudiniApi::SessionSyncInfo_InitEmptyStub;
  
  HoudiniApi::SessionSyncInfo_CreateFuncPtr
  HoudiniApi::SessionSyncInfo_Create = &HoudiniApi::SessionSyncInfo_CreateEmptyStub;
  


void
HoudiniApi::initialize_hapi(void* library_handle)
{
	if(!library_handle) return;

  HoudiniApi::CreateInProcessSession = (CreateInProcessSessionFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CreateInProcessSession");
  HoudiniApi::StartThriftSocketServer = (StartThriftSocketServerFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_StartThriftSocketServer");
  HoudiniApi::CreateThriftSocketSession = (CreateThriftSocketSessionFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CreateThriftSocketSession");
  HoudiniApi::StartThriftNamedPipeServer = (StartThriftNamedPipeServerFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_StartThriftNamedPipeServer");
  HoudiniApi::CreateThriftNamedPipeSession = (CreateThriftNamedPipeSessionFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CreateThriftNamedPipeSession");
  HoudiniApi::StartThriftSharedMemoryServer = (StartThriftSharedMemoryServerFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_StartThriftSharedMemoryServer");
  HoudiniApi::CreateThriftSharedMemorySession = (CreateThriftSharedMemorySessionFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CreateThriftSharedMemorySession");
  HoudiniApi::BindCustomImplementation = (BindCustomImplementationFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_BindCustomImplementation");
  HoudiniApi::CreateCustomSession = (CreateCustomSessionFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CreateCustomSession");
  HoudiniApi::IsSessionValid = (IsSessionValidFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_IsSessionValid");
  HoudiniApi::CloseSession = (CloseSessionFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CloseSession");
  HoudiniApi::IsInitialized = (IsInitializedFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_IsInitialized");
  HoudiniApi::Initialize = (InitializeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_Initialize");
  HoudiniApi::Cleanup = (CleanupFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_Cleanup");
  HoudiniApi::Shutdown = (ShutdownFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_Shutdown");
  HoudiniApi::StartPerformanceMonitorProfile = (StartPerformanceMonitorProfileFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_StartPerformanceMonitorProfile");
  HoudiniApi::StopPerformanceMonitorProfile = (StopPerformanceMonitorProfileFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_StopPerformanceMonitorProfile");
  HoudiniApi::GetEnvInt = (GetEnvIntFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetEnvInt");
  HoudiniApi::GetSessionEnvInt = (GetSessionEnvIntFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetSessionEnvInt");
  HoudiniApi::GetServerEnvInt = (GetServerEnvIntFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetServerEnvInt");
  HoudiniApi::GetServerEnvString = (GetServerEnvStringFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetServerEnvString");
  HoudiniApi::GetServerEnvVarCount = (GetServerEnvVarCountFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetServerEnvVarCount");
  HoudiniApi::GetServerEnvVarList = (GetServerEnvVarListFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetServerEnvVarList");
  HoudiniApi::SetServerEnvInt = (SetServerEnvIntFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetServerEnvInt");
  HoudiniApi::SetServerEnvString = (SetServerEnvStringFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetServerEnvString");
  HoudiniApi::GetStatus = (GetStatusFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetStatus");
  HoudiniApi::GetStatusStringBufLength = (GetStatusStringBufLengthFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetStatusStringBufLength");
  HoudiniApi::GetStatusString = (GetStatusStringFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetStatusString");
  HoudiniApi::ComposeNodeCookResult = (ComposeNodeCookResultFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ComposeNodeCookResult");
  HoudiniApi::GetComposedNodeCookResult = (GetComposedNodeCookResultFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetComposedNodeCookResult");
  HoudiniApi::GetNodeCookResultLength = (GetNodeCookResultLengthFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetNodeCookResultLength");
  HoudiniApi::GetNodeCookResult = (GetNodeCookResultFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetNodeCookResult");
  HoudiniApi::GetMessageNodeCount = (GetMessageNodeCountFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetMessageNodeCount");
  HoudiniApi::GetMessageNodeIds = (GetMessageNodeIdsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetMessageNodeIds");
  HoudiniApi::CheckForSpecificErrors = (CheckForSpecificErrorsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CheckForSpecificErrors");
  HoudiniApi::ClearConnectionError = (ClearConnectionErrorFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ClearConnectionError");
  HoudiniApi::GetConnectionErrorLength = (GetConnectionErrorLengthFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetConnectionErrorLength");
  HoudiniApi::GetConnectionError = (GetConnectionErrorFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetConnectionError");
  HoudiniApi::GetCookingTotalCount = (GetCookingTotalCountFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetCookingTotalCount");
  HoudiniApi::GetCookingCurrentCount = (GetCookingCurrentCountFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetCookingCurrentCount");
  HoudiniApi::Interrupt = (InterruptFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_Interrupt");
  HoudiniApi::ConvertTransform = (ConvertTransformFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ConvertTransform");
  HoudiniApi::ConvertMatrixToQuat = (ConvertMatrixToQuatFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ConvertMatrixToQuat");
  HoudiniApi::ConvertMatrixToEuler = (ConvertMatrixToEulerFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ConvertMatrixToEuler");
  HoudiniApi::ConvertTransformQuatToMatrix = (ConvertTransformQuatToMatrixFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ConvertTransformQuatToMatrix");
  HoudiniApi::ConvertTransformEulerToMatrix = (ConvertTransformEulerToMatrixFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ConvertTransformEulerToMatrix");
  HoudiniApi::PythonThreadInterpreterLock = (PythonThreadInterpreterLockFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_PythonThreadInterpreterLock");
  HoudiniApi::GetStringBufLength = (GetStringBufLengthFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetStringBufLength");
  HoudiniApi::GetString = (GetStringFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetString");
  HoudiniApi::SetCustomString = (SetCustomStringFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetCustomString");
  HoudiniApi::RemoveCustomString = (RemoveCustomStringFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_RemoveCustomString");
  HoudiniApi::GetStringBatchSize = (GetStringBatchSizeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetStringBatchSize");
  HoudiniApi::GetStringBatch = (GetStringBatchFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetStringBatch");
  HoudiniApi::GetTime = (GetTimeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetTime");
  HoudiniApi::SetTime = (SetTimeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetTime");
  HoudiniApi::GetUseHoudiniTime = (GetUseHoudiniTimeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetUseHoudiniTime");
  HoudiniApi::SetUseHoudiniTime = (SetUseHoudiniTimeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetUseHoudiniTime");
  HoudiniApi::GetTimelineOptions = (GetTimelineOptionsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetTimelineOptions");
  HoudiniApi::SetTimelineOptions = (SetTimelineOptionsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetTimelineOptions");
  HoudiniApi::GetCompositorOptions = (GetCompositorOptionsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetCompositorOptions");
  HoudiniApi::SetCompositorOptions = (SetCompositorOptionsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetCompositorOptions");
  HoudiniApi::LoadAssetLibraryFromFile = (LoadAssetLibraryFromFileFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_LoadAssetLibraryFromFile");
  HoudiniApi::LoadAssetLibraryFromMemory = (LoadAssetLibraryFromMemoryFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_LoadAssetLibraryFromMemory");
  HoudiniApi::GetAvailableAssetCount = (GetAvailableAssetCountFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAvailableAssetCount");
  HoudiniApi::GetAvailableAssets = (GetAvailableAssetsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAvailableAssets");
  HoudiniApi::GetAssetInfo = (GetAssetInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAssetInfo");
  HoudiniApi::GetAssetDefinitionParmCounts = (GetAssetDefinitionParmCountsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAssetDefinitionParmCounts");
  HoudiniApi::GetAssetDefinitionParmInfos = (GetAssetDefinitionParmInfosFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAssetDefinitionParmInfos");
  HoudiniApi::GetAssetDefinitionParmValues = (GetAssetDefinitionParmValuesFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAssetDefinitionParmValues");
  HoudiniApi::GetAssetDefinitionParmTagName = (GetAssetDefinitionParmTagNameFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAssetDefinitionParmTagName");
  HoudiniApi::GetAssetDefinitionParmTagValue = (GetAssetDefinitionParmTagValueFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAssetDefinitionParmTagValue");
  HoudiniApi::GetLoadedAssetLibraryCount = (GetLoadedAssetLibraryCountFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetLoadedAssetLibraryCount");
  HoudiniApi::GetAssetLibraryIds = (GetAssetLibraryIdsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAssetLibraryIds");
  HoudiniApi::GetAssetLibraryFilePath = (GetAssetLibraryFilePathFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAssetLibraryFilePath");
  HoudiniApi::LoadHIPFile = (LoadHIPFileFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_LoadHIPFile");
  HoudiniApi::MergeHIPFile = (MergeHIPFileFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_MergeHIPFile");
  HoudiniApi::SaveHIPFile = (SaveHIPFileFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SaveHIPFile");
  HoudiniApi::GetHIPFileNodeCount = (GetHIPFileNodeCountFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetHIPFileNodeCount");
  HoudiniApi::GetHIPFileNodeIds = (GetHIPFileNodeIdsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetHIPFileNodeIds");
  HoudiniApi::IsNodeValid = (IsNodeValidFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_IsNodeValid");
  HoudiniApi::GetNodeInfo = (GetNodeInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetNodeInfo");
  HoudiniApi::GetNodePath = (GetNodePathFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetNodePath");
  HoudiniApi::GetManagerNodeId = (GetManagerNodeIdFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetManagerNodeId");
  HoudiniApi::ComposeChildNodeList = (ComposeChildNodeListFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ComposeChildNodeList");
  HoudiniApi::GetComposedChildNodeList = (GetComposedChildNodeListFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetComposedChildNodeList");
  HoudiniApi::CreateNode = (CreateNodeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CreateNode");
  HoudiniApi::CreateInputNode = (CreateInputNodeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CreateInputNode");
  HoudiniApi::CreateInputCurveNode = (CreateInputCurveNodeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CreateInputCurveNode");
  HoudiniApi::CreateHeightFieldInput = (CreateHeightFieldInputFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CreateHeightFieldInput");
  HoudiniApi::CreateHeightfieldInputVolumeNode = (CreateHeightfieldInputVolumeNodeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CreateHeightfieldInputVolumeNode");
  HoudiniApi::CookNode = (CookNodeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CookNode");
  HoudiniApi::DeleteNode = (DeleteNodeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_DeleteNode");
  HoudiniApi::RenameNode = (RenameNodeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_RenameNode");
  HoudiniApi::ConnectNodeInput = (ConnectNodeInputFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ConnectNodeInput");
  HoudiniApi::DisconnectNodeInput = (DisconnectNodeInputFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_DisconnectNodeInput");
  HoudiniApi::QueryNodeInput = (QueryNodeInputFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_QueryNodeInput");
  HoudiniApi::GetNodeInputName = (GetNodeInputNameFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetNodeInputName");
  HoudiniApi::DisconnectNodeOutputsAt = (DisconnectNodeOutputsAtFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_DisconnectNodeOutputsAt");
  HoudiniApi::QueryNodeOutputConnectedCount = (QueryNodeOutputConnectedCountFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_QueryNodeOutputConnectedCount");
  HoudiniApi::QueryNodeOutputConnectedNodes = (QueryNodeOutputConnectedNodesFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_QueryNodeOutputConnectedNodes");
  HoudiniApi::GetNodeOutputName = (GetNodeOutputNameFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetNodeOutputName");
  HoudiniApi::GetNodeFromPath = (GetNodeFromPathFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetNodeFromPath");
  HoudiniApi::GetOutputNodeId = (GetOutputNodeIdFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetOutputNodeId");
  HoudiniApi::GetParameters = (GetParametersFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetParameters");
  HoudiniApi::GetParmInfo = (GetParmInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetParmInfo");
  HoudiniApi::GetParmIdFromName = (GetParmIdFromNameFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetParmIdFromName");
  HoudiniApi::GetParmInfoFromName = (GetParmInfoFromNameFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetParmInfoFromName");
  HoudiniApi::GetParmTagName = (GetParmTagNameFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetParmTagName");
  HoudiniApi::GetParmTagValue = (GetParmTagValueFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetParmTagValue");
  HoudiniApi::ParmHasTag = (ParmHasTagFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ParmHasTag");
  HoudiniApi::ParmHasExpression = (ParmHasExpressionFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ParmHasExpression");
  HoudiniApi::GetParmWithTag = (GetParmWithTagFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetParmWithTag");
  HoudiniApi::GetParmExpression = (GetParmExpressionFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetParmExpression");
  HoudiniApi::RevertParmToDefault = (RevertParmToDefaultFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_RevertParmToDefault");
  HoudiniApi::RevertParmToDefaults = (RevertParmToDefaultsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_RevertParmToDefaults");
  HoudiniApi::SetParmExpression = (SetParmExpressionFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetParmExpression");
  HoudiniApi::RemoveParmExpression = (RemoveParmExpressionFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_RemoveParmExpression");
  HoudiniApi::GetParmIntValue = (GetParmIntValueFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetParmIntValue");
  HoudiniApi::GetParmIntValues = (GetParmIntValuesFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetParmIntValues");
  HoudiniApi::GetParmFloatValue = (GetParmFloatValueFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetParmFloatValue");
  HoudiniApi::GetParmFloatValues = (GetParmFloatValuesFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetParmFloatValues");
  HoudiniApi::GetParmStringValue = (GetParmStringValueFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetParmStringValue");
  HoudiniApi::GetParmStringValues = (GetParmStringValuesFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetParmStringValues");
  HoudiniApi::GetParmNodeValue = (GetParmNodeValueFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetParmNodeValue");
  HoudiniApi::GetParmFile = (GetParmFileFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetParmFile");
  HoudiniApi::GetParmChoiceLists = (GetParmChoiceListsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetParmChoiceLists");
  HoudiniApi::SetParmIntValue = (SetParmIntValueFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetParmIntValue");
  HoudiniApi::SetParmIntValues = (SetParmIntValuesFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetParmIntValues");
  HoudiniApi::SetParmFloatValue = (SetParmFloatValueFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetParmFloatValue");
  HoudiniApi::SetParmFloatValues = (SetParmFloatValuesFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetParmFloatValues");
  HoudiniApi::SetParmStringValue = (SetParmStringValueFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetParmStringValue");
  HoudiniApi::SetParmNodeValue = (SetParmNodeValueFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetParmNodeValue");
  HoudiniApi::InsertMultiparmInstance = (InsertMultiparmInstanceFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_InsertMultiparmInstance");
  HoudiniApi::RemoveMultiparmInstance = (RemoveMultiparmInstanceFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_RemoveMultiparmInstance");
  HoudiniApi::GetHandleInfo = (GetHandleInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetHandleInfo");
  HoudiniApi::GetHandleBindingInfo = (GetHandleBindingInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetHandleBindingInfo");
  HoudiniApi::GetPresetBufLength = (GetPresetBufLengthFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetPresetBufLength");
  HoudiniApi::GetPreset = (GetPresetFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetPreset");
  HoudiniApi::SetPreset = (SetPresetFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetPreset");
  HoudiniApi::GetPresetCount = (GetPresetCountFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetPresetCount");
  HoudiniApi::GetPresetNames = (GetPresetNamesFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetPresetNames");
  HoudiniApi::GetObjectInfo = (GetObjectInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetObjectInfo");
  HoudiniApi::GetObjectTransform = (GetObjectTransformFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetObjectTransform");
  HoudiniApi::ComposeObjectList = (ComposeObjectListFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ComposeObjectList");
  HoudiniApi::GetComposedObjectList = (GetComposedObjectListFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetComposedObjectList");
  HoudiniApi::GetComposedObjectTransforms = (GetComposedObjectTransformsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetComposedObjectTransforms");
  HoudiniApi::GetInstancedObjectIds = (GetInstancedObjectIdsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetInstancedObjectIds");
  HoudiniApi::GetInstanceTransformsOnPart = (GetInstanceTransformsOnPartFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetInstanceTransformsOnPart");
  HoudiniApi::SetObjectTransform = (SetObjectTransformFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetObjectTransform");
  HoudiniApi::GetDisplayGeoInfo = (GetDisplayGeoInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetDisplayGeoInfo");
  HoudiniApi::GetOutputGeoCount = (GetOutputGeoCountFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetOutputGeoCount");
  HoudiniApi::GetOutputGeoInfos = (GetOutputGeoInfosFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetOutputGeoInfos");
  HoudiniApi::GetGeoInfo = (GetGeoInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetGeoInfo");
  HoudiniApi::GetPartInfo = (GetPartInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetPartInfo");
  HoudiniApi::GetEdgeCountOfEdgeGroup = (GetEdgeCountOfEdgeGroupFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetEdgeCountOfEdgeGroup");
  HoudiniApi::GetFaceCounts = (GetFaceCountsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetFaceCounts");
  HoudiniApi::GetVertexList = (GetVertexListFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetVertexList");
  HoudiniApi::GetAttributeInfo = (GetAttributeInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeInfo");
  HoudiniApi::GetAttributeNames = (GetAttributeNamesFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeNames");
  HoudiniApi::GetAttributeIntData = (GetAttributeIntDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeIntData");
  HoudiniApi::GetAttributeIntArrayData = (GetAttributeIntArrayDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeIntArrayData");
  HoudiniApi::GetAttributeUInt8Data = (GetAttributeUInt8DataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeUInt8Data");
  HoudiniApi::GetAttributeUInt8ArrayData = (GetAttributeUInt8ArrayDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeUInt8ArrayData");
  HoudiniApi::GetAttributeInt8Data = (GetAttributeInt8DataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeInt8Data");
  HoudiniApi::GetAttributeInt8ArrayData = (GetAttributeInt8ArrayDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeInt8ArrayData");
  HoudiniApi::GetAttributeInt16Data = (GetAttributeInt16DataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeInt16Data");
  HoudiniApi::GetAttributeInt16ArrayData = (GetAttributeInt16ArrayDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeInt16ArrayData");
  HoudiniApi::GetAttributeInt64Data = (GetAttributeInt64DataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeInt64Data");
  HoudiniApi::GetAttributeInt64ArrayData = (GetAttributeInt64ArrayDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeInt64ArrayData");
  HoudiniApi::GetAttributeFloatData = (GetAttributeFloatDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeFloatData");
  HoudiniApi::GetAttributeFloatArrayData = (GetAttributeFloatArrayDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeFloatArrayData");
  HoudiniApi::GetAttributeFloat64Data = (GetAttributeFloat64DataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeFloat64Data");
  HoudiniApi::GetAttributeFloat64ArrayData = (GetAttributeFloat64ArrayDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeFloat64ArrayData");
  HoudiniApi::GetAttributeStringData = (GetAttributeStringDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeStringData");
  HoudiniApi::GetAttributeStringArrayData = (GetAttributeStringArrayDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeStringArrayData");
  HoudiniApi::GetAttributeDictionaryData = (GetAttributeDictionaryDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeDictionaryData");
  HoudiniApi::GetAttributeDictionaryArrayData = (GetAttributeDictionaryArrayDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeDictionaryArrayData");
  HoudiniApi::GetAttributeIntDataAsync = (GetAttributeIntDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeIntDataAsync");
  HoudiniApi::GetAttributeUInt8DataAsync = (GetAttributeUInt8DataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeUInt8DataAsync");
  HoudiniApi::GetAttributeInt8DataAsync = (GetAttributeInt8DataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeInt8DataAsync");
  HoudiniApi::GetAttributeInt16DataAsync = (GetAttributeInt16DataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeInt16DataAsync");
  HoudiniApi::GetAttributeInt64DataAsync = (GetAttributeInt64DataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeInt64DataAsync");
  HoudiniApi::GetAttributeFloatDataAsync = (GetAttributeFloatDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeFloatDataAsync");
  HoudiniApi::GetAttributeFloat64DataAsync = (GetAttributeFloat64DataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeFloat64DataAsync");
  HoudiniApi::GetAttributeStringDataAsync = (GetAttributeStringDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeStringDataAsync");
  HoudiniApi::GetAttributeDictionaryDataAsync = (GetAttributeDictionaryDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeDictionaryDataAsync");
  HoudiniApi::GetAttributeIntArrayDataAsync = (GetAttributeIntArrayDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeIntArrayDataAsync");
  HoudiniApi::GetAttributeUInt8ArrayDataAsync = (GetAttributeUInt8ArrayDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeUInt8ArrayDataAsync");
  HoudiniApi::GetAttributeInt8ArrayDataAsync = (GetAttributeInt8ArrayDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeInt8ArrayDataAsync");
  HoudiniApi::GetAttributeInt16ArrayDataAsync = (GetAttributeInt16ArrayDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeInt16ArrayDataAsync");
  HoudiniApi::GetAttributeInt64ArrayDataAsync = (GetAttributeInt64ArrayDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeInt64ArrayDataAsync");
  HoudiniApi::GetAttributeFloatArrayDataAsync = (GetAttributeFloatArrayDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeFloatArrayDataAsync");
  HoudiniApi::GetAttributeFloat64ArrayDataAsync = (GetAttributeFloat64ArrayDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeFloat64ArrayDataAsync");
  HoudiniApi::GetAttributeStringArrayDataAsync = (GetAttributeStringArrayDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeStringArrayDataAsync");
  HoudiniApi::GetAttributeDictionaryArrayDataAsync = (GetAttributeDictionaryArrayDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetAttributeDictionaryArrayDataAsync");
  HoudiniApi::GetJobStatus = (GetJobStatusFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetJobStatus");
  HoudiniApi::GetGroupNames = (GetGroupNamesFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetGroupNames");
  HoudiniApi::GetGroupMembership = (GetGroupMembershipFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetGroupMembership");
  HoudiniApi::GetGroupCountOnPackedInstancePart = (GetGroupCountOnPackedInstancePartFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetGroupCountOnPackedInstancePart");
  HoudiniApi::GetGroupNamesOnPackedInstancePart = (GetGroupNamesOnPackedInstancePartFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetGroupNamesOnPackedInstancePart");
  HoudiniApi::GetGroupMembershipOnPackedInstancePart = (GetGroupMembershipOnPackedInstancePartFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetGroupMembershipOnPackedInstancePart");
  HoudiniApi::GetInstancedPartIds = (GetInstancedPartIdsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetInstancedPartIds");
  HoudiniApi::GetInstancerPartTransforms = (GetInstancerPartTransformsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetInstancerPartTransforms");
  HoudiniApi::SetPartInfo = (SetPartInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetPartInfo");
  HoudiniApi::SetFaceCounts = (SetFaceCountsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetFaceCounts");
  HoudiniApi::SetVertexList = (SetVertexListFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetVertexList");
  HoudiniApi::AddAttribute = (AddAttributeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_AddAttribute");
  HoudiniApi::DeleteAttribute = (DeleteAttributeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_DeleteAttribute");
  HoudiniApi::SetAttributeIntData = (SetAttributeIntDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeIntData");
  HoudiniApi::SetAttributeUInt8Data = (SetAttributeUInt8DataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeUInt8Data");
  HoudiniApi::SetAttributeInt8Data = (SetAttributeInt8DataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeInt8Data");
  HoudiniApi::SetAttributeInt16Data = (SetAttributeInt16DataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeInt16Data");
  HoudiniApi::SetAttributeInt64Data = (SetAttributeInt64DataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeInt64Data");
  HoudiniApi::SetAttributeFloatData = (SetAttributeFloatDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeFloatData");
  HoudiniApi::SetAttributeFloat64Data = (SetAttributeFloat64DataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeFloat64Data");
  HoudiniApi::SetAttributeStringData = (SetAttributeStringDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeStringData");
  HoudiniApi::SetAttributeIndexedStringData = (SetAttributeIndexedStringDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeIndexedStringData");
  HoudiniApi::SetAttributeStringUniqueData = (SetAttributeStringUniqueDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeStringUniqueData");
  HoudiniApi::SetAttributeIntUniqueData = (SetAttributeIntUniqueDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeIntUniqueData");
  HoudiniApi::SetAttributeUInt8UniqueData = (SetAttributeUInt8UniqueDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeUInt8UniqueData");
  HoudiniApi::SetAttributeInt8UniqueData = (SetAttributeInt8UniqueDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeInt8UniqueData");
  HoudiniApi::SetAttributeInt16UniqueData = (SetAttributeInt16UniqueDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeInt16UniqueData");
  HoudiniApi::SetAttributeInt64UniqueData = (SetAttributeInt64UniqueDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeInt64UniqueData");
  HoudiniApi::SetAttributeFloatUniqueData = (SetAttributeFloatUniqueDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeFloatUniqueData");
  HoudiniApi::SetAttributeFloat64UniqueData = (SetAttributeFloat64UniqueDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeFloat64UniqueData");
  HoudiniApi::SetAttributeDictionaryData = (SetAttributeDictionaryDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeDictionaryData");
  HoudiniApi::SetAttributeIntArrayData = (SetAttributeIntArrayDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeIntArrayData");
  HoudiniApi::SetAttributeUInt8ArrayData = (SetAttributeUInt8ArrayDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeUInt8ArrayData");
  HoudiniApi::SetAttributeInt8ArrayData = (SetAttributeInt8ArrayDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeInt8ArrayData");
  HoudiniApi::SetAttributeInt16ArrayData = (SetAttributeInt16ArrayDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeInt16ArrayData");
  HoudiniApi::SetAttributeInt64ArrayData = (SetAttributeInt64ArrayDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeInt64ArrayData");
  HoudiniApi::SetAttributeFloatArrayData = (SetAttributeFloatArrayDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeFloatArrayData");
  HoudiniApi::SetAttributeFloat64ArrayData = (SetAttributeFloat64ArrayDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeFloat64ArrayData");
  HoudiniApi::SetAttributeStringArrayData = (SetAttributeStringArrayDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeStringArrayData");
  HoudiniApi::SetAttributeDictionaryArrayData = (SetAttributeDictionaryArrayDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeDictionaryArrayData");
  HoudiniApi::SetAttributeIntDataAsync = (SetAttributeIntDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeIntDataAsync");
  HoudiniApi::SetAttributeUInt8DataAsync = (SetAttributeUInt8DataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeUInt8DataAsync");
  HoudiniApi::SetAttributeInt8DataAsync = (SetAttributeInt8DataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeInt8DataAsync");
  HoudiniApi::SetAttributeInt16DataAsync = (SetAttributeInt16DataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeInt16DataAsync");
  HoudiniApi::SetAttributeInt64DataAsync = (SetAttributeInt64DataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeInt64DataAsync");
  HoudiniApi::SetAttributeFloatDataAsync = (SetAttributeFloatDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeFloatDataAsync");
  HoudiniApi::SetAttributeFloat64DataAsync = (SetAttributeFloat64DataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeFloat64DataAsync");
  HoudiniApi::SetAttributeStringDataAsync = (SetAttributeStringDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeStringDataAsync");
  HoudiniApi::SetAttributeIndexedStringDataAsync = (SetAttributeIndexedStringDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeIndexedStringDataAsync");
  HoudiniApi::SetAttributeStringUniqueDataAsync = (SetAttributeStringUniqueDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeStringUniqueDataAsync");
  HoudiniApi::SetAttributeIntUniqueDataAsync = (SetAttributeIntUniqueDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeIntUniqueDataAsync");
  HoudiniApi::SetAttributeUInt8UniqueDataAsync = (SetAttributeUInt8UniqueDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeUInt8UniqueDataAsync");
  HoudiniApi::SetAttributeInt8UniqueDataAsync = (SetAttributeInt8UniqueDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeInt8UniqueDataAsync");
  HoudiniApi::SetAttributeInt16UniqueDataAsync = (SetAttributeInt16UniqueDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeInt16UniqueDataAsync");
  HoudiniApi::SetAttributeInt64UniqueDataAsync = (SetAttributeInt64UniqueDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeInt64UniqueDataAsync");
  HoudiniApi::SetAttributeFloatUniqueDataAsync = (SetAttributeFloatUniqueDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeFloatUniqueDataAsync");
  HoudiniApi::SetAttributeFloat64UniqueDataAsync = (SetAttributeFloat64UniqueDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeFloat64UniqueDataAsync");
  HoudiniApi::SetAttributeDictionaryDataAsync = (SetAttributeDictionaryDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeDictionaryDataAsync");
  HoudiniApi::SetAttributeIntArrayDataAsync = (SetAttributeIntArrayDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeIntArrayDataAsync");
  HoudiniApi::SetAttributeUInt8ArrayDataAsync = (SetAttributeUInt8ArrayDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeUInt8ArrayDataAsync");
  HoudiniApi::SetAttributeInt8ArrayDataAsync = (SetAttributeInt8ArrayDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeInt8ArrayDataAsync");
  HoudiniApi::SetAttributeInt16ArrayDataAsync = (SetAttributeInt16ArrayDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeInt16ArrayDataAsync");
  HoudiniApi::SetAttributeInt64ArrayDataAsync = (SetAttributeInt64ArrayDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeInt64ArrayDataAsync");
  HoudiniApi::SetAttributeFloatArrayDataAsync = (SetAttributeFloatArrayDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeFloatArrayDataAsync");
  HoudiniApi::SetAttributeFloat64ArrayDataAsync = (SetAttributeFloat64ArrayDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeFloat64ArrayDataAsync");
  HoudiniApi::SetAttributeStringArrayDataAsync = (SetAttributeStringArrayDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeStringArrayDataAsync");
  HoudiniApi::SetAttributeDictionaryArrayDataAsync = (SetAttributeDictionaryArrayDataAsyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAttributeDictionaryArrayDataAsync");
  HoudiniApi::AddGroup = (AddGroupFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_AddGroup");
  HoudiniApi::DeleteGroup = (DeleteGroupFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_DeleteGroup");
  HoudiniApi::SetGroupMembership = (SetGroupMembershipFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetGroupMembership");
  HoudiniApi::CommitGeo = (CommitGeoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CommitGeo");
  HoudiniApi::RevertGeo = (RevertGeoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_RevertGeo");
  HoudiniApi::GetMaterialNodeIdsOnFaces = (GetMaterialNodeIdsOnFacesFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetMaterialNodeIdsOnFaces");
  HoudiniApi::GetMaterialInfo = (GetMaterialInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetMaterialInfo");
  HoudiniApi::RenderCOPToImage = (RenderCOPToImageFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_RenderCOPToImage");
  HoudiniApi::RenderTextureToImage = (RenderTextureToImageFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_RenderTextureToImage");
  HoudiniApi::GetImageInfo = (GetImageInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetImageInfo");
  HoudiniApi::SetImageInfo = (SetImageInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetImageInfo");
  HoudiniApi::GetImagePlaneCount = (GetImagePlaneCountFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetImagePlaneCount");
  HoudiniApi::GetImagePlanes = (GetImagePlanesFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetImagePlanes");
  HoudiniApi::ExtractImageToFile = (ExtractImageToFileFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ExtractImageToFile");
  HoudiniApi::GetImageFilePath = (GetImageFilePathFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetImageFilePath");
  HoudiniApi::ExtractImageToMemory = (ExtractImageToMemoryFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ExtractImageToMemory");
  HoudiniApi::GetImageMemoryBuffer = (GetImageMemoryBufferFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetImageMemoryBuffer");
  HoudiniApi::GetSupportedImageFileFormatCount = (GetSupportedImageFileFormatCountFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetSupportedImageFileFormatCount");
  HoudiniApi::GetSupportedImageFileFormats = (GetSupportedImageFileFormatsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetSupportedImageFileFormats");
  HoudiniApi::SetAnimCurve = (SetAnimCurveFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetAnimCurve");
  HoudiniApi::SetTransformAnimCurve = (SetTransformAnimCurveFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetTransformAnimCurve");
  HoudiniApi::ResetSimulation = (ResetSimulationFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ResetSimulation");
  HoudiniApi::GetVolumeInfo = (GetVolumeInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetVolumeInfo");
  HoudiniApi::GetFirstVolumeTile = (GetFirstVolumeTileFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetFirstVolumeTile");
  HoudiniApi::GetNextVolumeTile = (GetNextVolumeTileFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetNextVolumeTile");
  HoudiniApi::GetVolumeVoxelFloatData = (GetVolumeVoxelFloatDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetVolumeVoxelFloatData");
  HoudiniApi::GetVolumeTileFloatData = (GetVolumeTileFloatDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetVolumeTileFloatData");
  HoudiniApi::GetVolumeVoxelIntData = (GetVolumeVoxelIntDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetVolumeVoxelIntData");
  HoudiniApi::GetVolumeTileIntData = (GetVolumeTileIntDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetVolumeTileIntData");
  HoudiniApi::GetHeightFieldData = (GetHeightFieldDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetHeightFieldData");
  HoudiniApi::SetVolumeInfo = (SetVolumeInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetVolumeInfo");
  HoudiniApi::SetVolumeTileFloatData = (SetVolumeTileFloatDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetVolumeTileFloatData");
  HoudiniApi::SetVolumeTileIntData = (SetVolumeTileIntDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetVolumeTileIntData");
  HoudiniApi::SetVolumeVoxelFloatData = (SetVolumeVoxelFloatDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetVolumeVoxelFloatData");
  HoudiniApi::SetVolumeVoxelIntData = (SetVolumeVoxelIntDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetVolumeVoxelIntData");
  HoudiniApi::GetVolumeBounds = (GetVolumeBoundsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetVolumeBounds");
  HoudiniApi::SetHeightFieldData = (SetHeightFieldDataFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetHeightFieldData");
  HoudiniApi::GetVolumeVisualInfo = (GetVolumeVisualInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetVolumeVisualInfo");
  HoudiniApi::GetCurveInfo = (GetCurveInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetCurveInfo");
  HoudiniApi::GetCurveCounts = (GetCurveCountsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetCurveCounts");
  HoudiniApi::GetCurveOrders = (GetCurveOrdersFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetCurveOrders");
  HoudiniApi::GetCurveKnots = (GetCurveKnotsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetCurveKnots");
  HoudiniApi::SetCurveInfo = (SetCurveInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetCurveInfo");
  HoudiniApi::SetCurveCounts = (SetCurveCountsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetCurveCounts");
  HoudiniApi::SetCurveOrders = (SetCurveOrdersFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetCurveOrders");
  HoudiniApi::SetCurveKnots = (SetCurveKnotsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetCurveKnots");
  HoudiniApi::GetInputCurveInfo = (GetInputCurveInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetInputCurveInfo");
  HoudiniApi::SetInputCurveInfo = (SetInputCurveInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetInputCurveInfo");
  HoudiniApi::SetInputCurvePositions = (SetInputCurvePositionsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetInputCurvePositions");
  HoudiniApi::SetInputCurvePositionsRotationsScales = (SetInputCurvePositionsRotationsScalesFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetInputCurvePositionsRotationsScales");
  HoudiniApi::GetBoxInfo = (GetBoxInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetBoxInfo");
  HoudiniApi::GetSphereInfo = (GetSphereInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetSphereInfo");
  HoudiniApi::GetActiveCacheCount = (GetActiveCacheCountFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetActiveCacheCount");
  HoudiniApi::GetActiveCacheNames = (GetActiveCacheNamesFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetActiveCacheNames");
  HoudiniApi::GetCacheProperty = (GetCachePropertyFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetCacheProperty");
  HoudiniApi::SetCacheProperty = (SetCachePropertyFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetCacheProperty");
  HoudiniApi::SaveGeoToFile = (SaveGeoToFileFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SaveGeoToFile");
  HoudiniApi::LoadGeoFromFile = (LoadGeoFromFileFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_LoadGeoFromFile");
  HoudiniApi::SaveNodeToFile = (SaveNodeToFileFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SaveNodeToFile");
  HoudiniApi::LoadNodeFromFile = (LoadNodeFromFileFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_LoadNodeFromFile");
  HoudiniApi::GetGeoSize = (GetGeoSizeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetGeoSize");
  HoudiniApi::SaveGeoToMemory = (SaveGeoToMemoryFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SaveGeoToMemory");
  HoudiniApi::LoadGeoFromMemory = (LoadGeoFromMemoryFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_LoadGeoFromMemory");
  HoudiniApi::SetNodeDisplay = (SetNodeDisplayFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetNodeDisplay");
  HoudiniApi::GetTotalCookCount = (GetTotalCookCountFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetTotalCookCount");
  HoudiniApi::SetSessionSync = (SetSessionSyncFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetSessionSync");
  HoudiniApi::GetViewport = (GetViewportFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetViewport");
  HoudiniApi::SetViewport = (SetViewportFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetViewport");
  HoudiniApi::GetSessionSyncInfo = (GetSessionSyncInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetSessionSyncInfo");
  HoudiniApi::SetSessionSyncInfo = (SetSessionSyncInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetSessionSyncInfo");
  HoudiniApi::GetPDGGraphContexts = (GetPDGGraphContextsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetPDGGraphContexts");
  HoudiniApi::GetPDGGraphContextsCount = (GetPDGGraphContextsCountFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetPDGGraphContextsCount");
  HoudiniApi::GetPDGGraphContextId = (GetPDGGraphContextIdFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetPDGGraphContextId");
  HoudiniApi::CookPDG = (CookPDGFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CookPDG");
  HoudiniApi::CookPDGAllOutputs = (CookPDGAllOutputsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CookPDGAllOutputs");
  HoudiniApi::GetPDGEvents = (GetPDGEventsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetPDGEvents");
  HoudiniApi::GetPDGState = (GetPDGStateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetPDGState");
  HoudiniApi::CreateWorkItem = (CreateWorkItemFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CreateWorkItem");
  HoudiniApi::GetWorkItemInfo = (GetWorkItemInfoFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetWorkItemInfo");
  HoudiniApi::SetWorkItemIntAttribute = (SetWorkItemIntAttributeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetWorkItemIntAttribute");
  HoudiniApi::SetWorkItemFloatAttribute = (SetWorkItemFloatAttributeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetWorkItemFloatAttribute");
  HoudiniApi::SetWorkItemStringAttribute = (SetWorkItemStringAttributeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SetWorkItemStringAttribute");
  HoudiniApi::CommitWorkItems = (CommitWorkItemsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CommitWorkItems");
  HoudiniApi::GetNumWorkItems = (GetNumWorkItemsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetNumWorkItems");
  HoudiniApi::GetWorkItems = (GetWorkItemsFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetWorkItems");
  HoudiniApi::GetWorkItemAttributeSize = (GetWorkItemAttributeSizeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetWorkItemAttributeSize");
  HoudiniApi::GetWorkItemIntAttribute = (GetWorkItemIntAttributeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetWorkItemIntAttribute");
  HoudiniApi::GetWorkItemFloatAttribute = (GetWorkItemFloatAttributeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetWorkItemFloatAttribute");
  HoudiniApi::GetWorkItemStringAttribute = (GetWorkItemStringAttributeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetWorkItemStringAttribute");
  HoudiniApi::GetWorkItemOutputFiles = (GetWorkItemOutputFilesFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GetWorkItemOutputFiles");
  HoudiniApi::DirtyPDGNode = (DirtyPDGNodeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_DirtyPDGNode");
  HoudiniApi::PausePDGCook = (PausePDGCookFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_PausePDGCook");
  HoudiniApi::CancelPDGCook = (CancelPDGCookFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CancelPDGCook");
  HoudiniApi::SessionInfo_Init = (SessionInfo_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SessionInfo_Init");
  HoudiniApi::SessionInfo_Create = (SessionInfo_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SessionInfo_Create");
  HoudiniApi::ThriftServerOptions_Init = (ThriftServerOptions_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ThriftServerOptions_Init");
  HoudiniApi::ThriftServerOptions_Create = (ThriftServerOptions_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ThriftServerOptions_Create");
  HoudiniApi::TimelineOptions_Init = (TimelineOptions_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_TimelineOptions_Init");
  HoudiniApi::TimelineOptions_Create = (TimelineOptions_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_TimelineOptions_Create");
  HoudiniApi::CompositorOptions_Init = (CompositorOptions_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CompositorOptions_Init");
  HoudiniApi::CompositorOptions_Create = (CompositorOptions_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CompositorOptions_Create");
  HoudiniApi::AssetInfo_Init = (AssetInfo_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_AssetInfo_Init");
  HoudiniApi::AssetInfo_Create = (AssetInfo_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_AssetInfo_Create");
  HoudiniApi::CookOptions_Init = (CookOptions_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CookOptions_Init");
  HoudiniApi::CookOptions_Create = (CookOptions_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CookOptions_Create");
  HoudiniApi::CookOptions_AreEqual = (CookOptions_AreEqualFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CookOptions_AreEqual");
  HoudiniApi::NodeInfo_Init = (NodeInfo_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_NodeInfo_Init");
  HoudiniApi::NodeInfo_Create = (NodeInfo_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_NodeInfo_Create");
  HoudiniApi::ParmInfo_Init = (ParmInfo_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ParmInfo_Init");
  HoudiniApi::ParmInfo_Create = (ParmInfo_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ParmInfo_Create");
  HoudiniApi::ParmInfo_IsInt = (ParmInfo_IsIntFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ParmInfo_IsInt");
  HoudiniApi::ParmInfo_IsFloat = (ParmInfo_IsFloatFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ParmInfo_IsFloat");
  HoudiniApi::ParmInfo_IsString = (ParmInfo_IsStringFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ParmInfo_IsString");
  HoudiniApi::ParmInfo_IsPath = (ParmInfo_IsPathFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ParmInfo_IsPath");
  HoudiniApi::ParmInfo_IsNode = (ParmInfo_IsNodeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ParmInfo_IsNode");
  HoudiniApi::ParmInfo_IsNonValue = (ParmInfo_IsNonValueFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ParmInfo_IsNonValue");
  HoudiniApi::ParmInfo_GetIntValueCount = (ParmInfo_GetIntValueCountFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ParmInfo_GetIntValueCount");
  HoudiniApi::ParmInfo_GetFloatValueCount = (ParmInfo_GetFloatValueCountFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ParmInfo_GetFloatValueCount");
  HoudiniApi::ParmInfo_GetStringValueCount = (ParmInfo_GetStringValueCountFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ParmInfo_GetStringValueCount");
  HoudiniApi::ParmChoiceInfo_Init = (ParmChoiceInfo_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ParmChoiceInfo_Init");
  HoudiniApi::ParmChoiceInfo_Create = (ParmChoiceInfo_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ParmChoiceInfo_Create");
  HoudiniApi::HandleInfo_Init = (HandleInfo_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_HandleInfo_Init");
  HoudiniApi::HandleInfo_Create = (HandleInfo_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_HandleInfo_Create");
  HoudiniApi::HandleBindingInfo_Init = (HandleBindingInfo_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_HandleBindingInfo_Init");
  HoudiniApi::HandleBindingInfo_Create = (HandleBindingInfo_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_HandleBindingInfo_Create");
  HoudiniApi::ObjectInfo_Init = (ObjectInfo_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ObjectInfo_Init");
  HoudiniApi::ObjectInfo_Create = (ObjectInfo_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ObjectInfo_Create");
  HoudiniApi::GeoInfo_Init = (GeoInfo_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GeoInfo_Init");
  HoudiniApi::GeoInfo_Create = (GeoInfo_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GeoInfo_Create");
  HoudiniApi::GeoInfo_GetGroupCountByType = (GeoInfo_GetGroupCountByTypeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_GeoInfo_GetGroupCountByType");
  HoudiniApi::PartInfo_Init = (PartInfo_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_PartInfo_Init");
  HoudiniApi::PartInfo_Create = (PartInfo_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_PartInfo_Create");
  HoudiniApi::PartInfo_GetElementCountByAttributeOwner = (PartInfo_GetElementCountByAttributeOwnerFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_PartInfo_GetElementCountByAttributeOwner");
  HoudiniApi::PartInfo_GetElementCountByGroupType = (PartInfo_GetElementCountByGroupTypeFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_PartInfo_GetElementCountByGroupType");
  HoudiniApi::PartInfo_GetAttributeCountByOwner = (PartInfo_GetAttributeCountByOwnerFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_PartInfo_GetAttributeCountByOwner");
  HoudiniApi::AttributeInfo_Init = (AttributeInfo_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_AttributeInfo_Init");
  HoudiniApi::AttributeInfo_Create = (AttributeInfo_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_AttributeInfo_Create");
  HoudiniApi::MaterialInfo_Init = (MaterialInfo_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_MaterialInfo_Init");
  HoudiniApi::MaterialInfo_Create = (MaterialInfo_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_MaterialInfo_Create");
  HoudiniApi::ImageFileFormat_Init = (ImageFileFormat_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ImageFileFormat_Init");
  HoudiniApi::ImageFileFormat_Create = (ImageFileFormat_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ImageFileFormat_Create");
  HoudiniApi::ImageInfo_Init = (ImageInfo_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ImageInfo_Init");
  HoudiniApi::ImageInfo_Create = (ImageInfo_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_ImageInfo_Create");
  HoudiniApi::Keyframe_Init = (Keyframe_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_Keyframe_Init");
  HoudiniApi::Keyframe_Create = (Keyframe_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_Keyframe_Create");
  HoudiniApi::VolumeInfo_Init = (VolumeInfo_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_VolumeInfo_Init");
  HoudiniApi::VolumeInfo_Create = (VolumeInfo_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_VolumeInfo_Create");
  HoudiniApi::VolumeTileInfo_Init = (VolumeTileInfo_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_VolumeTileInfo_Init");
  HoudiniApi::VolumeTileInfo_Create = (VolumeTileInfo_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_VolumeTileInfo_Create");
  HoudiniApi::CurveInfo_Init = (CurveInfo_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CurveInfo_Init");
  HoudiniApi::CurveInfo_Create = (CurveInfo_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_CurveInfo_Create");
  HoudiniApi::InputCurveInfo_Init = (InputCurveInfo_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_InputCurveInfo_Init");
  HoudiniApi::InputCurveInfo_Create = (InputCurveInfo_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_InputCurveInfo_Create");
  HoudiniApi::Transform_Init = (Transform_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_Transform_Init");
  HoudiniApi::Transform_Create = (Transform_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_Transform_Create");
  HoudiniApi::TransformEuler_Init = (TransformEuler_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_TransformEuler_Init");
  HoudiniApi::TransformEuler_Create = (TransformEuler_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_TransformEuler_Create");
  HoudiniApi::Viewport_Init = (Viewport_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_Viewport_Init");
  HoudiniApi::Viewport_Create = (Viewport_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_Viewport_Create");
  HoudiniApi::SessionSyncInfo_Init = (SessionSyncInfo_InitFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SessionSyncInfo_Init");
  HoudiniApi::SessionSyncInfo_Create = (SessionSyncInfo_CreateFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_SessionSyncInfo_Create");


}


void
HoudiniApi::finalize_hapi()
{
    
  HoudiniApi::CreateInProcessSession = &HoudiniApi::CreateInProcessSessionEmptyStub;
  HoudiniApi::StartThriftSocketServer = &HoudiniApi::StartThriftSocketServerEmptyStub;
  HoudiniApi::CreateThriftSocketSession = &HoudiniApi::CreateThriftSocketSessionEmptyStub;
  HoudiniApi::StartThriftNamedPipeServer = &HoudiniApi::StartThriftNamedPipeServerEmptyStub;
  HoudiniApi::CreateThriftNamedPipeSession = &HoudiniApi::CreateThriftNamedPipeSessionEmptyStub;
  HoudiniApi::StartThriftSharedMemoryServer = &HoudiniApi::StartThriftSharedMemoryServerEmptyStub;
  HoudiniApi::CreateThriftSharedMemorySession = &HoudiniApi::CreateThriftSharedMemorySessionEmptyStub;
  HoudiniApi::BindCustomImplementation = &HoudiniApi::BindCustomImplementationEmptyStub;
  HoudiniApi::CreateCustomSession = &HoudiniApi::CreateCustomSessionEmptyStub;
  HoudiniApi::IsSessionValid = &HoudiniApi::IsSessionValidEmptyStub;
  HoudiniApi::CloseSession = &HoudiniApi::CloseSessionEmptyStub;
  HoudiniApi::IsInitialized = &HoudiniApi::IsInitializedEmptyStub;
  HoudiniApi::Initialize = &HoudiniApi::InitializeEmptyStub;
  HoudiniApi::Cleanup = &HoudiniApi::CleanupEmptyStub;
  HoudiniApi::Shutdown = &HoudiniApi::ShutdownEmptyStub;
  HoudiniApi::StartPerformanceMonitorProfile = &HoudiniApi::StartPerformanceMonitorProfileEmptyStub;
  HoudiniApi::StopPerformanceMonitorProfile = &HoudiniApi::StopPerformanceMonitorProfileEmptyStub;
  HoudiniApi::GetEnvInt = &HoudiniApi::GetEnvIntEmptyStub;
  HoudiniApi::GetSessionEnvInt = &HoudiniApi::GetSessionEnvIntEmptyStub;
  HoudiniApi::GetServerEnvInt = &HoudiniApi::GetServerEnvIntEmptyStub;
  HoudiniApi::GetServerEnvString = &HoudiniApi::GetServerEnvStringEmptyStub;
  HoudiniApi::GetServerEnvVarCount = &HoudiniApi::GetServerEnvVarCountEmptyStub;
  HoudiniApi::GetServerEnvVarList = &HoudiniApi::GetServerEnvVarListEmptyStub;
  HoudiniApi::SetServerEnvInt = &HoudiniApi::SetServerEnvIntEmptyStub;
  HoudiniApi::SetServerEnvString = &HoudiniApi::SetServerEnvStringEmptyStub;
  HoudiniApi::GetStatus = &HoudiniApi::GetStatusEmptyStub;
  HoudiniApi::GetStatusStringBufLength = &HoudiniApi::GetStatusStringBufLengthEmptyStub;
  HoudiniApi::GetStatusString = &HoudiniApi::GetStatusStringEmptyStub;
  HoudiniApi::ComposeNodeCookResult = &HoudiniApi::ComposeNodeCookResultEmptyStub;
  HoudiniApi::GetComposedNodeCookResult = &HoudiniApi::GetComposedNodeCookResultEmptyStub;
  HoudiniApi::GetNodeCookResultLength = &HoudiniApi::GetNodeCookResultLengthEmptyStub;
  HoudiniApi::GetNodeCookResult = &HoudiniApi::GetNodeCookResultEmptyStub;
  HoudiniApi::GetMessageNodeCount = &HoudiniApi::GetMessageNodeCountEmptyStub;
  HoudiniApi::GetMessageNodeIds = &HoudiniApi::GetMessageNodeIdsEmptyStub;
  HoudiniApi::CheckForSpecificErrors = &HoudiniApi::CheckForSpecificErrorsEmptyStub;
  HoudiniApi::ClearConnectionError = &HoudiniApi::ClearConnectionErrorEmptyStub;
  HoudiniApi::GetConnectionErrorLength = &HoudiniApi::GetConnectionErrorLengthEmptyStub;
  HoudiniApi::GetConnectionError = &HoudiniApi::GetConnectionErrorEmptyStub;
  HoudiniApi::GetCookingTotalCount = &HoudiniApi::GetCookingTotalCountEmptyStub;
  HoudiniApi::GetCookingCurrentCount = &HoudiniApi::GetCookingCurrentCountEmptyStub;
  HoudiniApi::Interrupt = &HoudiniApi::InterruptEmptyStub;
  HoudiniApi::ConvertTransform = &HoudiniApi::ConvertTransformEmptyStub;
  HoudiniApi::ConvertMatrixToQuat = &HoudiniApi::ConvertMatrixToQuatEmptyStub;
  HoudiniApi::ConvertMatrixToEuler = &HoudiniApi::ConvertMatrixToEulerEmptyStub;
  HoudiniApi::ConvertTransformQuatToMatrix = &HoudiniApi::ConvertTransformQuatToMatrixEmptyStub;
  HoudiniApi::ConvertTransformEulerToMatrix = &HoudiniApi::ConvertTransformEulerToMatrixEmptyStub;
  HoudiniApi::PythonThreadInterpreterLock = &HoudiniApi::PythonThreadInterpreterLockEmptyStub;
  HoudiniApi::GetStringBufLength = &HoudiniApi::GetStringBufLengthEmptyStub;
  HoudiniApi::GetString = &HoudiniApi::GetStringEmptyStub;
  HoudiniApi::SetCustomString = &HoudiniApi::SetCustomStringEmptyStub;
  HoudiniApi::RemoveCustomString = &HoudiniApi::RemoveCustomStringEmptyStub;
  HoudiniApi::GetStringBatchSize = &HoudiniApi::GetStringBatchSizeEmptyStub;
  HoudiniApi::GetStringBatch = &HoudiniApi::GetStringBatchEmptyStub;
  HoudiniApi::GetTime = &HoudiniApi::GetTimeEmptyStub;
  HoudiniApi::SetTime = &HoudiniApi::SetTimeEmptyStub;
  HoudiniApi::GetUseHoudiniTime = &HoudiniApi::GetUseHoudiniTimeEmptyStub;
  HoudiniApi::SetUseHoudiniTime = &HoudiniApi::SetUseHoudiniTimeEmptyStub;
  HoudiniApi::GetTimelineOptions = &HoudiniApi::GetTimelineOptionsEmptyStub;
  HoudiniApi::SetTimelineOptions = &HoudiniApi::SetTimelineOptionsEmptyStub;
  HoudiniApi::GetCompositorOptions = &HoudiniApi::GetCompositorOptionsEmptyStub;
  HoudiniApi::SetCompositorOptions = &HoudiniApi::SetCompositorOptionsEmptyStub;
  HoudiniApi::LoadAssetLibraryFromFile = &HoudiniApi::LoadAssetLibraryFromFileEmptyStub;
  HoudiniApi::LoadAssetLibraryFromMemory = &HoudiniApi::LoadAssetLibraryFromMemoryEmptyStub;
  HoudiniApi::GetAvailableAssetCount = &HoudiniApi::GetAvailableAssetCountEmptyStub;
  HoudiniApi::GetAvailableAssets = &HoudiniApi::GetAvailableAssetsEmptyStub;
  HoudiniApi::GetAssetInfo = &HoudiniApi::GetAssetInfoEmptyStub;
  HoudiniApi::GetAssetDefinitionParmCounts = &HoudiniApi::GetAssetDefinitionParmCountsEmptyStub;
  HoudiniApi::GetAssetDefinitionParmInfos = &HoudiniApi::GetAssetDefinitionParmInfosEmptyStub;
  HoudiniApi::GetAssetDefinitionParmValues = &HoudiniApi::GetAssetDefinitionParmValuesEmptyStub;
  HoudiniApi::GetAssetDefinitionParmTagName = &HoudiniApi::GetAssetDefinitionParmTagNameEmptyStub;
  HoudiniApi::GetAssetDefinitionParmTagValue = &HoudiniApi::GetAssetDefinitionParmTagValueEmptyStub;
  HoudiniApi::GetLoadedAssetLibraryCount = &HoudiniApi::GetLoadedAssetLibraryCountEmptyStub;
  HoudiniApi::GetAssetLibraryIds = &HoudiniApi::GetAssetLibraryIdsEmptyStub;
  HoudiniApi::GetAssetLibraryFilePath = &HoudiniApi::GetAssetLibraryFilePathEmptyStub;
  HoudiniApi::LoadHIPFile = &HoudiniApi::LoadHIPFileEmptyStub;
  HoudiniApi::MergeHIPFile = &HoudiniApi::MergeHIPFileEmptyStub;
  HoudiniApi::SaveHIPFile = &HoudiniApi::SaveHIPFileEmptyStub;
  HoudiniApi::GetHIPFileNodeCount = &HoudiniApi::GetHIPFileNodeCountEmptyStub;
  HoudiniApi::GetHIPFileNodeIds = &HoudiniApi::GetHIPFileNodeIdsEmptyStub;
  HoudiniApi::IsNodeValid = &HoudiniApi::IsNodeValidEmptyStub;
  HoudiniApi::GetNodeInfo = &HoudiniApi::GetNodeInfoEmptyStub;
  HoudiniApi::GetNodePath = &HoudiniApi::GetNodePathEmptyStub;
  HoudiniApi::GetManagerNodeId = &HoudiniApi::GetManagerNodeIdEmptyStub;
  HoudiniApi::ComposeChildNodeList = &HoudiniApi::ComposeChildNodeListEmptyStub;
  HoudiniApi::GetComposedChildNodeList = &HoudiniApi::GetComposedChildNodeListEmptyStub;
  HoudiniApi::CreateNode = &HoudiniApi::CreateNodeEmptyStub;
  HoudiniApi::CreateInputNode = &HoudiniApi::CreateInputNodeEmptyStub;
  HoudiniApi::CreateInputCurveNode = &HoudiniApi::CreateInputCurveNodeEmptyStub;
  HoudiniApi::CreateHeightFieldInput = &HoudiniApi::CreateHeightFieldInputEmptyStub;
  HoudiniApi::CreateHeightfieldInputVolumeNode = &HoudiniApi::CreateHeightfieldInputVolumeNodeEmptyStub;
  HoudiniApi::CookNode = &HoudiniApi::CookNodeEmptyStub;
  HoudiniApi::DeleteNode = &HoudiniApi::DeleteNodeEmptyStub;
  HoudiniApi::RenameNode = &HoudiniApi::RenameNodeEmptyStub;
  HoudiniApi::ConnectNodeInput = &HoudiniApi::ConnectNodeInputEmptyStub;
  HoudiniApi::DisconnectNodeInput = &HoudiniApi::DisconnectNodeInputEmptyStub;
  HoudiniApi::QueryNodeInput = &HoudiniApi::QueryNodeInputEmptyStub;
  HoudiniApi::GetNodeInputName = &HoudiniApi::GetNodeInputNameEmptyStub;
  HoudiniApi::DisconnectNodeOutputsAt = &HoudiniApi::DisconnectNodeOutputsAtEmptyStub;
  HoudiniApi::QueryNodeOutputConnectedCount = &HoudiniApi::QueryNodeOutputConnectedCountEmptyStub;
  HoudiniApi::QueryNodeOutputConnectedNodes = &HoudiniApi::QueryNodeOutputConnectedNodesEmptyStub;
  HoudiniApi::GetNodeOutputName = &HoudiniApi::GetNodeOutputNameEmptyStub;
  HoudiniApi::GetNodeFromPath = &HoudiniApi::GetNodeFromPathEmptyStub;
  HoudiniApi::GetOutputNodeId = &HoudiniApi::GetOutputNodeIdEmptyStub;
  HoudiniApi::GetParameters = &HoudiniApi::GetParametersEmptyStub;
  HoudiniApi::GetParmInfo = &HoudiniApi::GetParmInfoEmptyStub;
  HoudiniApi::GetParmIdFromName = &HoudiniApi::GetParmIdFromNameEmptyStub;
  HoudiniApi::GetParmInfoFromName = &HoudiniApi::GetParmInfoFromNameEmptyStub;
  HoudiniApi::GetParmTagName = &HoudiniApi::GetParmTagNameEmptyStub;
  HoudiniApi::GetParmTagValue = &HoudiniApi::GetParmTagValueEmptyStub;
  HoudiniApi::ParmHasTag = &HoudiniApi::ParmHasTagEmptyStub;
  HoudiniApi::ParmHasExpression = &HoudiniApi::ParmHasExpressionEmptyStub;
  HoudiniApi::GetParmWithTag = &HoudiniApi::GetParmWithTagEmptyStub;
  HoudiniApi::GetParmExpression = &HoudiniApi::GetParmExpressionEmptyStub;
  HoudiniApi::RevertParmToDefault = &HoudiniApi::RevertParmToDefaultEmptyStub;
  HoudiniApi::RevertParmToDefaults = &HoudiniApi::RevertParmToDefaultsEmptyStub;
  HoudiniApi::SetParmExpression = &HoudiniApi::SetParmExpressionEmptyStub;
  HoudiniApi::RemoveParmExpression = &HoudiniApi::RemoveParmExpressionEmptyStub;
  HoudiniApi::GetParmIntValue = &HoudiniApi::GetParmIntValueEmptyStub;
  HoudiniApi::GetParmIntValues = &HoudiniApi::GetParmIntValuesEmptyStub;
  HoudiniApi::GetParmFloatValue = &HoudiniApi::GetParmFloatValueEmptyStub;
  HoudiniApi::GetParmFloatValues = &HoudiniApi::GetParmFloatValuesEmptyStub;
  HoudiniApi::GetParmStringValue = &HoudiniApi::GetParmStringValueEmptyStub;
  HoudiniApi::GetParmStringValues = &HoudiniApi::GetParmStringValuesEmptyStub;
  HoudiniApi::GetParmNodeValue = &HoudiniApi::GetParmNodeValueEmptyStub;
  HoudiniApi::GetParmFile = &HoudiniApi::GetParmFileEmptyStub;
  HoudiniApi::GetParmChoiceLists = &HoudiniApi::GetParmChoiceListsEmptyStub;
  HoudiniApi::SetParmIntValue = &HoudiniApi::SetParmIntValueEmptyStub;
  HoudiniApi::SetParmIntValues = &HoudiniApi::SetParmIntValuesEmptyStub;
  HoudiniApi::SetParmFloatValue = &HoudiniApi::SetParmFloatValueEmptyStub;
  HoudiniApi::SetParmFloatValues = &HoudiniApi::SetParmFloatValuesEmptyStub;
  HoudiniApi::SetParmStringValue = &HoudiniApi::SetParmStringValueEmptyStub;
  HoudiniApi::SetParmNodeValue = &HoudiniApi::SetParmNodeValueEmptyStub;
  HoudiniApi::InsertMultiparmInstance = &HoudiniApi::InsertMultiparmInstanceEmptyStub;
  HoudiniApi::RemoveMultiparmInstance = &HoudiniApi::RemoveMultiparmInstanceEmptyStub;
  HoudiniApi::GetHandleInfo = &HoudiniApi::GetHandleInfoEmptyStub;
  HoudiniApi::GetHandleBindingInfo = &HoudiniApi::GetHandleBindingInfoEmptyStub;
  HoudiniApi::GetPresetBufLength = &HoudiniApi::GetPresetBufLengthEmptyStub;
  HoudiniApi::GetPreset = &HoudiniApi::GetPresetEmptyStub;
  HoudiniApi::SetPreset = &HoudiniApi::SetPresetEmptyStub;
  HoudiniApi::GetPresetCount = &HoudiniApi::GetPresetCountEmptyStub;
  HoudiniApi::GetPresetNames = &HoudiniApi::GetPresetNamesEmptyStub;
  HoudiniApi::GetObjectInfo = &HoudiniApi::GetObjectInfoEmptyStub;
  HoudiniApi::GetObjectTransform = &HoudiniApi::GetObjectTransformEmptyStub;
  HoudiniApi::ComposeObjectList = &HoudiniApi::ComposeObjectListEmptyStub;
  HoudiniApi::GetComposedObjectList = &HoudiniApi::GetComposedObjectListEmptyStub;
  HoudiniApi::GetComposedObjectTransforms = &HoudiniApi::GetComposedObjectTransformsEmptyStub;
  HoudiniApi::GetInstancedObjectIds = &HoudiniApi::GetInstancedObjectIdsEmptyStub;
  HoudiniApi::GetInstanceTransformsOnPart = &HoudiniApi::GetInstanceTransformsOnPartEmptyStub;
  HoudiniApi::SetObjectTransform = &HoudiniApi::SetObjectTransformEmptyStub;
  HoudiniApi::GetDisplayGeoInfo = &HoudiniApi::GetDisplayGeoInfoEmptyStub;
  HoudiniApi::GetOutputGeoCount = &HoudiniApi::GetOutputGeoCountEmptyStub;
  HoudiniApi::GetOutputGeoInfos = &HoudiniApi::GetOutputGeoInfosEmptyStub;
  HoudiniApi::GetGeoInfo = &HoudiniApi::GetGeoInfoEmptyStub;
  HoudiniApi::GetPartInfo = &HoudiniApi::GetPartInfoEmptyStub;
  HoudiniApi::GetEdgeCountOfEdgeGroup = &HoudiniApi::GetEdgeCountOfEdgeGroupEmptyStub;
  HoudiniApi::GetFaceCounts = &HoudiniApi::GetFaceCountsEmptyStub;
  HoudiniApi::GetVertexList = &HoudiniApi::GetVertexListEmptyStub;
  HoudiniApi::GetAttributeInfo = &HoudiniApi::GetAttributeInfoEmptyStub;
  HoudiniApi::GetAttributeNames = &HoudiniApi::GetAttributeNamesEmptyStub;
  HoudiniApi::GetAttributeIntData = &HoudiniApi::GetAttributeIntDataEmptyStub;
  HoudiniApi::GetAttributeIntArrayData = &HoudiniApi::GetAttributeIntArrayDataEmptyStub;
  HoudiniApi::GetAttributeUInt8Data = &HoudiniApi::GetAttributeUInt8DataEmptyStub;
  HoudiniApi::GetAttributeUInt8ArrayData = &HoudiniApi::GetAttributeUInt8ArrayDataEmptyStub;
  HoudiniApi::GetAttributeInt8Data = &HoudiniApi::GetAttributeInt8DataEmptyStub;
  HoudiniApi::GetAttributeInt8ArrayData = &HoudiniApi::GetAttributeInt8ArrayDataEmptyStub;
  HoudiniApi::GetAttributeInt16Data = &HoudiniApi::GetAttributeInt16DataEmptyStub;
  HoudiniApi::GetAttributeInt16ArrayData = &HoudiniApi::GetAttributeInt16ArrayDataEmptyStub;
  HoudiniApi::GetAttributeInt64Data = &HoudiniApi::GetAttributeInt64DataEmptyStub;
  HoudiniApi::GetAttributeInt64ArrayData = &HoudiniApi::GetAttributeInt64ArrayDataEmptyStub;
  HoudiniApi::GetAttributeFloatData = &HoudiniApi::GetAttributeFloatDataEmptyStub;
  HoudiniApi::GetAttributeFloatArrayData = &HoudiniApi::GetAttributeFloatArrayDataEmptyStub;
  HoudiniApi::GetAttributeFloat64Data = &HoudiniApi::GetAttributeFloat64DataEmptyStub;
  HoudiniApi::GetAttributeFloat64ArrayData = &HoudiniApi::GetAttributeFloat64ArrayDataEmptyStub;
  HoudiniApi::GetAttributeStringData = &HoudiniApi::GetAttributeStringDataEmptyStub;
  HoudiniApi::GetAttributeStringArrayData = &HoudiniApi::GetAttributeStringArrayDataEmptyStub;
  HoudiniApi::GetAttributeDictionaryData = &HoudiniApi::GetAttributeDictionaryDataEmptyStub;
  HoudiniApi::GetAttributeDictionaryArrayData = &HoudiniApi::GetAttributeDictionaryArrayDataEmptyStub;
  HoudiniApi::GetAttributeIntDataAsync = &HoudiniApi::GetAttributeIntDataAsyncEmptyStub;
  HoudiniApi::GetAttributeUInt8DataAsync = &HoudiniApi::GetAttributeUInt8DataAsyncEmptyStub;
  HoudiniApi::GetAttributeInt8DataAsync = &HoudiniApi::GetAttributeInt8DataAsyncEmptyStub;
  HoudiniApi::GetAttributeInt16DataAsync = &HoudiniApi::GetAttributeInt16DataAsyncEmptyStub;
  HoudiniApi::GetAttributeInt64DataAsync = &HoudiniApi::GetAttributeInt64DataAsyncEmptyStub;
  HoudiniApi::GetAttributeFloatDataAsync = &HoudiniApi::GetAttributeFloatDataAsyncEmptyStub;
  HoudiniApi::GetAttributeFloat64DataAsync = &HoudiniApi::GetAttributeFloat64DataAsyncEmptyStub;
  HoudiniApi::GetAttributeStringDataAsync = &HoudiniApi::GetAttributeStringDataAsyncEmptyStub;
  HoudiniApi::GetAttributeDictionaryDataAsync = &HoudiniApi::GetAttributeDictionaryDataAsyncEmptyStub;
  HoudiniApi::GetAttributeIntArrayDataAsync = &HoudiniApi::GetAttributeIntArrayDataAsyncEmptyStub;
  HoudiniApi::GetAttributeUInt8ArrayDataAsync = &HoudiniApi::GetAttributeUInt8ArrayDataAsyncEmptyStub;
  HoudiniApi::GetAttributeInt8ArrayDataAsync = &HoudiniApi::GetAttributeInt8ArrayDataAsyncEmptyStub;
  HoudiniApi::GetAttributeInt16ArrayDataAsync = &HoudiniApi::GetAttributeInt16ArrayDataAsyncEmptyStub;
  HoudiniApi::GetAttributeInt64ArrayDataAsync = &HoudiniApi::GetAttributeInt64ArrayDataAsyncEmptyStub;
  HoudiniApi::GetAttributeFloatArrayDataAsync = &HoudiniApi::GetAttributeFloatArrayDataAsyncEmptyStub;
  HoudiniApi::GetAttributeFloat64ArrayDataAsync = &HoudiniApi::GetAttributeFloat64ArrayDataAsyncEmptyStub;
  HoudiniApi::GetAttributeStringArrayDataAsync = &HoudiniApi::GetAttributeStringArrayDataAsyncEmptyStub;
  HoudiniApi::GetAttributeDictionaryArrayDataAsync = &HoudiniApi::GetAttributeDictionaryArrayDataAsyncEmptyStub;
  HoudiniApi::GetJobStatus = &HoudiniApi::GetJobStatusEmptyStub;
  HoudiniApi::GetGroupNames = &HoudiniApi::GetGroupNamesEmptyStub;
  HoudiniApi::GetGroupMembership = &HoudiniApi::GetGroupMembershipEmptyStub;
  HoudiniApi::GetGroupCountOnPackedInstancePart = &HoudiniApi::GetGroupCountOnPackedInstancePartEmptyStub;
  HoudiniApi::GetGroupNamesOnPackedInstancePart = &HoudiniApi::GetGroupNamesOnPackedInstancePartEmptyStub;
  HoudiniApi::GetGroupMembershipOnPackedInstancePart = &HoudiniApi::GetGroupMembershipOnPackedInstancePartEmptyStub;
  HoudiniApi::GetInstancedPartIds = &HoudiniApi::GetInstancedPartIdsEmptyStub;
  HoudiniApi::GetInstancerPartTransforms = &HoudiniApi::GetInstancerPartTransformsEmptyStub;
  HoudiniApi::SetPartInfo = &HoudiniApi::SetPartInfoEmptyStub;
  HoudiniApi::SetFaceCounts = &HoudiniApi::SetFaceCountsEmptyStub;
  HoudiniApi::SetVertexList = &HoudiniApi::SetVertexListEmptyStub;
  HoudiniApi::AddAttribute = &HoudiniApi::AddAttributeEmptyStub;
  HoudiniApi::DeleteAttribute = &HoudiniApi::DeleteAttributeEmptyStub;
  HoudiniApi::SetAttributeIntData = &HoudiniApi::SetAttributeIntDataEmptyStub;
  HoudiniApi::SetAttributeUInt8Data = &HoudiniApi::SetAttributeUInt8DataEmptyStub;
  HoudiniApi::SetAttributeInt8Data = &HoudiniApi::SetAttributeInt8DataEmptyStub;
  HoudiniApi::SetAttributeInt16Data = &HoudiniApi::SetAttributeInt16DataEmptyStub;
  HoudiniApi::SetAttributeInt64Data = &HoudiniApi::SetAttributeInt64DataEmptyStub;
  HoudiniApi::SetAttributeFloatData = &HoudiniApi::SetAttributeFloatDataEmptyStub;
  HoudiniApi::SetAttributeFloat64Data = &HoudiniApi::SetAttributeFloat64DataEmptyStub;
  HoudiniApi::SetAttributeStringData = &HoudiniApi::SetAttributeStringDataEmptyStub;
  HoudiniApi::SetAttributeIndexedStringData = &HoudiniApi::SetAttributeIndexedStringDataEmptyStub;
  HoudiniApi::SetAttributeStringUniqueData = &HoudiniApi::SetAttributeStringUniqueDataEmptyStub;
  HoudiniApi::SetAttributeIntUniqueData = &HoudiniApi::SetAttributeIntUniqueDataEmptyStub;
  HoudiniApi::SetAttributeUInt8UniqueData = &HoudiniApi::SetAttributeUInt8UniqueDataEmptyStub;
  HoudiniApi::SetAttributeInt8UniqueData = &HoudiniApi::SetAttributeInt8UniqueDataEmptyStub;
  HoudiniApi::SetAttributeInt16UniqueData = &HoudiniApi::SetAttributeInt16UniqueDataEmptyStub;
  HoudiniApi::SetAttributeInt64UniqueData = &HoudiniApi::SetAttributeInt64UniqueDataEmptyStub;
  HoudiniApi::SetAttributeFloatUniqueData = &HoudiniApi::SetAttributeFloatUniqueDataEmptyStub;
  HoudiniApi::SetAttributeFloat64UniqueData = &HoudiniApi::SetAttributeFloat64UniqueDataEmptyStub;
  HoudiniApi::SetAttributeDictionaryData = &HoudiniApi::SetAttributeDictionaryDataEmptyStub;
  HoudiniApi::SetAttributeIntArrayData = &HoudiniApi::SetAttributeIntArrayDataEmptyStub;
  HoudiniApi::SetAttributeUInt8ArrayData = &HoudiniApi::SetAttributeUInt8ArrayDataEmptyStub;
  HoudiniApi::SetAttributeInt8ArrayData = &HoudiniApi::SetAttributeInt8ArrayDataEmptyStub;
  HoudiniApi::SetAttributeInt16ArrayData = &HoudiniApi::SetAttributeInt16ArrayDataEmptyStub;
  HoudiniApi::SetAttributeInt64ArrayData = &HoudiniApi::SetAttributeInt64ArrayDataEmptyStub;
  HoudiniApi::SetAttributeFloatArrayData = &HoudiniApi::SetAttributeFloatArrayDataEmptyStub;
  HoudiniApi::SetAttributeFloat64ArrayData = &HoudiniApi::SetAttributeFloat64ArrayDataEmptyStub;
  HoudiniApi::SetAttributeStringArrayData = &HoudiniApi::SetAttributeStringArrayDataEmptyStub;
  HoudiniApi::SetAttributeDictionaryArrayData = &HoudiniApi::SetAttributeDictionaryArrayDataEmptyStub;
  HoudiniApi::SetAttributeIntDataAsync = &HoudiniApi::SetAttributeIntDataAsyncEmptyStub;
  HoudiniApi::SetAttributeUInt8DataAsync = &HoudiniApi::SetAttributeUInt8DataAsyncEmptyStub;
  HoudiniApi::SetAttributeInt8DataAsync = &HoudiniApi::SetAttributeInt8DataAsyncEmptyStub;
  HoudiniApi::SetAttributeInt16DataAsync = &HoudiniApi::SetAttributeInt16DataAsyncEmptyStub;
  HoudiniApi::SetAttributeInt64DataAsync = &HoudiniApi::SetAttributeInt64DataAsyncEmptyStub;
  HoudiniApi::SetAttributeFloatDataAsync = &HoudiniApi::SetAttributeFloatDataAsyncEmptyStub;
  HoudiniApi::SetAttributeFloat64DataAsync = &HoudiniApi::SetAttributeFloat64DataAsyncEmptyStub;
  HoudiniApi::SetAttributeStringDataAsync = &HoudiniApi::SetAttributeStringDataAsyncEmptyStub;
  HoudiniApi::SetAttributeIndexedStringDataAsync = &HoudiniApi::SetAttributeIndexedStringDataAsyncEmptyStub;
  HoudiniApi::SetAttributeStringUniqueDataAsync = &HoudiniApi::SetAttributeStringUniqueDataAsyncEmptyStub;
  HoudiniApi::SetAttributeIntUniqueDataAsync = &HoudiniApi::SetAttributeIntUniqueDataAsyncEmptyStub;
  HoudiniApi::SetAttributeUInt8UniqueDataAsync = &HoudiniApi::SetAttributeUInt8UniqueDataAsyncEmptyStub;
  HoudiniApi::SetAttributeInt8UniqueDataAsync = &HoudiniApi::SetAttributeInt8UniqueDataAsyncEmptyStub;
  HoudiniApi::SetAttributeInt16UniqueDataAsync = &HoudiniApi::SetAttributeInt16UniqueDataAsyncEmptyStub;
  HoudiniApi::SetAttributeInt64UniqueDataAsync = &HoudiniApi::SetAttributeInt64UniqueDataAsyncEmptyStub;
  HoudiniApi::SetAttributeFloatUniqueDataAsync = &HoudiniApi::SetAttributeFloatUniqueDataAsyncEmptyStub;
  HoudiniApi::SetAttributeFloat64UniqueDataAsync = &HoudiniApi::SetAttributeFloat64UniqueDataAsyncEmptyStub;
  HoudiniApi::SetAttributeDictionaryDataAsync = &HoudiniApi::SetAttributeDictionaryDataAsyncEmptyStub;
  HoudiniApi::SetAttributeIntArrayDataAsync = &HoudiniApi::SetAttributeIntArrayDataAsyncEmptyStub;
  HoudiniApi::SetAttributeUInt8ArrayDataAsync = &HoudiniApi::SetAttributeUInt8ArrayDataAsyncEmptyStub;
  HoudiniApi::SetAttributeInt8ArrayDataAsync = &HoudiniApi::SetAttributeInt8ArrayDataAsyncEmptyStub;
  HoudiniApi::SetAttributeInt16ArrayDataAsync = &HoudiniApi::SetAttributeInt16ArrayDataAsyncEmptyStub;
  HoudiniApi::SetAttributeInt64ArrayDataAsync = &HoudiniApi::SetAttributeInt64ArrayDataAsyncEmptyStub;
  HoudiniApi::SetAttributeFloatArrayDataAsync = &HoudiniApi::SetAttributeFloatArrayDataAsyncEmptyStub;
  HoudiniApi::SetAttributeFloat64ArrayDataAsync = &HoudiniApi::SetAttributeFloat64ArrayDataAsyncEmptyStub;
  HoudiniApi::SetAttributeStringArrayDataAsync = &HoudiniApi::SetAttributeStringArrayDataAsyncEmptyStub;
  HoudiniApi::SetAttributeDictionaryArrayDataAsync = &HoudiniApi::SetAttributeDictionaryArrayDataAsyncEmptyStub;
  HoudiniApi::AddGroup = &HoudiniApi::AddGroupEmptyStub;
  HoudiniApi::DeleteGroup = &HoudiniApi::DeleteGroupEmptyStub;
  HoudiniApi::SetGroupMembership = &HoudiniApi::SetGroupMembershipEmptyStub;
  HoudiniApi::CommitGeo = &HoudiniApi::CommitGeoEmptyStub;
  HoudiniApi::RevertGeo = &HoudiniApi::RevertGeoEmptyStub;
  HoudiniApi::GetMaterialNodeIdsOnFaces = &HoudiniApi::GetMaterialNodeIdsOnFacesEmptyStub;
  HoudiniApi::GetMaterialInfo = &HoudiniApi::GetMaterialInfoEmptyStub;
  HoudiniApi::RenderCOPToImage = &HoudiniApi::RenderCOPToImageEmptyStub;
  HoudiniApi::RenderTextureToImage = &HoudiniApi::RenderTextureToImageEmptyStub;
  HoudiniApi::GetImageInfo = &HoudiniApi::GetImageInfoEmptyStub;
  HoudiniApi::SetImageInfo = &HoudiniApi::SetImageInfoEmptyStub;
  HoudiniApi::GetImagePlaneCount = &HoudiniApi::GetImagePlaneCountEmptyStub;
  HoudiniApi::GetImagePlanes = &HoudiniApi::GetImagePlanesEmptyStub;
  HoudiniApi::ExtractImageToFile = &HoudiniApi::ExtractImageToFileEmptyStub;
  HoudiniApi::GetImageFilePath = &HoudiniApi::GetImageFilePathEmptyStub;
  HoudiniApi::ExtractImageToMemory = &HoudiniApi::ExtractImageToMemoryEmptyStub;
  HoudiniApi::GetImageMemoryBuffer = &HoudiniApi::GetImageMemoryBufferEmptyStub;
  HoudiniApi::GetSupportedImageFileFormatCount = &HoudiniApi::GetSupportedImageFileFormatCountEmptyStub;
  HoudiniApi::GetSupportedImageFileFormats = &HoudiniApi::GetSupportedImageFileFormatsEmptyStub;
  HoudiniApi::SetAnimCurve = &HoudiniApi::SetAnimCurveEmptyStub;
  HoudiniApi::SetTransformAnimCurve = &HoudiniApi::SetTransformAnimCurveEmptyStub;
  HoudiniApi::ResetSimulation = &HoudiniApi::ResetSimulationEmptyStub;
  HoudiniApi::GetVolumeInfo = &HoudiniApi::GetVolumeInfoEmptyStub;
  HoudiniApi::GetFirstVolumeTile = &HoudiniApi::GetFirstVolumeTileEmptyStub;
  HoudiniApi::GetNextVolumeTile = &HoudiniApi::GetNextVolumeTileEmptyStub;
  HoudiniApi::GetVolumeVoxelFloatData = &HoudiniApi::GetVolumeVoxelFloatDataEmptyStub;
  HoudiniApi::GetVolumeTileFloatData = &HoudiniApi::GetVolumeTileFloatDataEmptyStub;
  HoudiniApi::GetVolumeVoxelIntData = &HoudiniApi::GetVolumeVoxelIntDataEmptyStub;
  HoudiniApi::GetVolumeTileIntData = &HoudiniApi::GetVolumeTileIntDataEmptyStub;
  HoudiniApi::GetHeightFieldData = &HoudiniApi::GetHeightFieldDataEmptyStub;
  HoudiniApi::SetVolumeInfo = &HoudiniApi::SetVolumeInfoEmptyStub;
  HoudiniApi::SetVolumeTileFloatData = &HoudiniApi::SetVolumeTileFloatDataEmptyStub;
  HoudiniApi::SetVolumeTileIntData = &HoudiniApi::SetVolumeTileIntDataEmptyStub;
  HoudiniApi::SetVolumeVoxelFloatData = &HoudiniApi::SetVolumeVoxelFloatDataEmptyStub;
  HoudiniApi::SetVolumeVoxelIntData = &HoudiniApi::SetVolumeVoxelIntDataEmptyStub;
  HoudiniApi::GetVolumeBounds = &HoudiniApi::GetVolumeBoundsEmptyStub;
  HoudiniApi::SetHeightFieldData = &HoudiniApi::SetHeightFieldDataEmptyStub;
  HoudiniApi::GetVolumeVisualInfo = &HoudiniApi::GetVolumeVisualInfoEmptyStub;
  HoudiniApi::GetCurveInfo = &HoudiniApi::GetCurveInfoEmptyStub;
  HoudiniApi::GetCurveCounts = &HoudiniApi::GetCurveCountsEmptyStub;
  HoudiniApi::GetCurveOrders = &HoudiniApi::GetCurveOrdersEmptyStub;
  HoudiniApi::GetCurveKnots = &HoudiniApi::GetCurveKnotsEmptyStub;
  HoudiniApi::SetCurveInfo = &HoudiniApi::SetCurveInfoEmptyStub;
  HoudiniApi::SetCurveCounts = &HoudiniApi::SetCurveCountsEmptyStub;
  HoudiniApi::SetCurveOrders = &HoudiniApi::SetCurveOrdersEmptyStub;
  HoudiniApi::SetCurveKnots = &HoudiniApi::SetCurveKnotsEmptyStub;
  HoudiniApi::GetInputCurveInfo = &HoudiniApi::GetInputCurveInfoEmptyStub;
  HoudiniApi::SetInputCurveInfo = &HoudiniApi::SetInputCurveInfoEmptyStub;
  HoudiniApi::SetInputCurvePositions = &HoudiniApi::SetInputCurvePositionsEmptyStub;
  HoudiniApi::SetInputCurvePositionsRotationsScales = &HoudiniApi::SetInputCurvePositionsRotationsScalesEmptyStub;
  HoudiniApi::GetBoxInfo = &HoudiniApi::GetBoxInfoEmptyStub;
  HoudiniApi::GetSphereInfo = &HoudiniApi::GetSphereInfoEmptyStub;
  HoudiniApi::GetActiveCacheCount = &HoudiniApi::GetActiveCacheCountEmptyStub;
  HoudiniApi::GetActiveCacheNames = &HoudiniApi::GetActiveCacheNamesEmptyStub;
  HoudiniApi::GetCacheProperty = &HoudiniApi::GetCachePropertyEmptyStub;
  HoudiniApi::SetCacheProperty = &HoudiniApi::SetCachePropertyEmptyStub;
  HoudiniApi::SaveGeoToFile = &HoudiniApi::SaveGeoToFileEmptyStub;
  HoudiniApi::LoadGeoFromFile = &HoudiniApi::LoadGeoFromFileEmptyStub;
  HoudiniApi::SaveNodeToFile = &HoudiniApi::SaveNodeToFileEmptyStub;
  HoudiniApi::LoadNodeFromFile = &HoudiniApi::LoadNodeFromFileEmptyStub;
  HoudiniApi::GetGeoSize = &HoudiniApi::GetGeoSizeEmptyStub;
  HoudiniApi::SaveGeoToMemory = &HoudiniApi::SaveGeoToMemoryEmptyStub;
  HoudiniApi::LoadGeoFromMemory = &HoudiniApi::LoadGeoFromMemoryEmptyStub;
  HoudiniApi::SetNodeDisplay = &HoudiniApi::SetNodeDisplayEmptyStub;
  HoudiniApi::GetTotalCookCount = &HoudiniApi::GetTotalCookCountEmptyStub;
  HoudiniApi::SetSessionSync = &HoudiniApi::SetSessionSyncEmptyStub;
  HoudiniApi::GetViewport = &HoudiniApi::GetViewportEmptyStub;
  HoudiniApi::SetViewport = &HoudiniApi::SetViewportEmptyStub;
  HoudiniApi::GetSessionSyncInfo = &HoudiniApi::GetSessionSyncInfoEmptyStub;
  HoudiniApi::SetSessionSyncInfo = &HoudiniApi::SetSessionSyncInfoEmptyStub;
  HoudiniApi::GetPDGGraphContexts = &HoudiniApi::GetPDGGraphContextsEmptyStub;
  HoudiniApi::GetPDGGraphContextsCount = &HoudiniApi::GetPDGGraphContextsCountEmptyStub;
  HoudiniApi::GetPDGGraphContextId = &HoudiniApi::GetPDGGraphContextIdEmptyStub;
  HoudiniApi::CookPDG = &HoudiniApi::CookPDGEmptyStub;
  HoudiniApi::CookPDGAllOutputs = &HoudiniApi::CookPDGAllOutputsEmptyStub;
  HoudiniApi::GetPDGEvents = &HoudiniApi::GetPDGEventsEmptyStub;
  HoudiniApi::GetPDGState = &HoudiniApi::GetPDGStateEmptyStub;
  HoudiniApi::CreateWorkItem = &HoudiniApi::CreateWorkItemEmptyStub;
  HoudiniApi::GetWorkItemInfo = &HoudiniApi::GetWorkItemInfoEmptyStub;
  HoudiniApi::SetWorkItemIntAttribute = &HoudiniApi::SetWorkItemIntAttributeEmptyStub;
  HoudiniApi::SetWorkItemFloatAttribute = &HoudiniApi::SetWorkItemFloatAttributeEmptyStub;
  HoudiniApi::SetWorkItemStringAttribute = &HoudiniApi::SetWorkItemStringAttributeEmptyStub;
  HoudiniApi::CommitWorkItems = &HoudiniApi::CommitWorkItemsEmptyStub;
  HoudiniApi::GetNumWorkItems = &HoudiniApi::GetNumWorkItemsEmptyStub;
  HoudiniApi::GetWorkItems = &HoudiniApi::GetWorkItemsEmptyStub;
  HoudiniApi::GetWorkItemAttributeSize = &HoudiniApi::GetWorkItemAttributeSizeEmptyStub;
  HoudiniApi::GetWorkItemIntAttribute = &HoudiniApi::GetWorkItemIntAttributeEmptyStub;
  HoudiniApi::GetWorkItemFloatAttribute = &HoudiniApi::GetWorkItemFloatAttributeEmptyStub;
  HoudiniApi::GetWorkItemStringAttribute = &HoudiniApi::GetWorkItemStringAttributeEmptyStub;
  HoudiniApi::GetWorkItemOutputFiles = &HoudiniApi::GetWorkItemOutputFilesEmptyStub;
  HoudiniApi::DirtyPDGNode = &HoudiniApi::DirtyPDGNodeEmptyStub;
  HoudiniApi::PausePDGCook = &HoudiniApi::PausePDGCookEmptyStub;
  HoudiniApi::CancelPDGCook = &HoudiniApi::CancelPDGCookEmptyStub;
  HoudiniApi::SessionInfo_Init = &HoudiniApi::SessionInfo_InitEmptyStub;
  HoudiniApi::SessionInfo_Create = &HoudiniApi::SessionInfo_CreateEmptyStub;
  HoudiniApi::ThriftServerOptions_Init = &HoudiniApi::ThriftServerOptions_InitEmptyStub;
  HoudiniApi::ThriftServerOptions_Create = &HoudiniApi::ThriftServerOptions_CreateEmptyStub;
  HoudiniApi::TimelineOptions_Init = &HoudiniApi::TimelineOptions_InitEmptyStub;
  HoudiniApi::TimelineOptions_Create = &HoudiniApi::TimelineOptions_CreateEmptyStub;
  HoudiniApi::CompositorOptions_Init = &HoudiniApi::CompositorOptions_InitEmptyStub;
  HoudiniApi::CompositorOptions_Create = &HoudiniApi::CompositorOptions_CreateEmptyStub;
  HoudiniApi::AssetInfo_Init = &HoudiniApi::AssetInfo_InitEmptyStub;
  HoudiniApi::AssetInfo_Create = &HoudiniApi::AssetInfo_CreateEmptyStub;
  HoudiniApi::CookOptions_Init = &HoudiniApi::CookOptions_InitEmptyStub;
  HoudiniApi::CookOptions_Create = &HoudiniApi::CookOptions_CreateEmptyStub;
  HoudiniApi::CookOptions_AreEqual = &HoudiniApi::CookOptions_AreEqualEmptyStub;
  HoudiniApi::NodeInfo_Init = &HoudiniApi::NodeInfo_InitEmptyStub;
  HoudiniApi::NodeInfo_Create = &HoudiniApi::NodeInfo_CreateEmptyStub;
  HoudiniApi::ParmInfo_Init = &HoudiniApi::ParmInfo_InitEmptyStub;
  HoudiniApi::ParmInfo_Create = &HoudiniApi::ParmInfo_CreateEmptyStub;
  HoudiniApi::ParmInfo_IsInt = &HoudiniApi::ParmInfo_IsIntEmptyStub;
  HoudiniApi::ParmInfo_IsFloat = &HoudiniApi::ParmInfo_IsFloatEmptyStub;
  HoudiniApi::ParmInfo_IsString = &HoudiniApi::ParmInfo_IsStringEmptyStub;
  HoudiniApi::ParmInfo_IsPath = &HoudiniApi::ParmInfo_IsPathEmptyStub;
  HoudiniApi::ParmInfo_IsNode = &HoudiniApi::ParmInfo_IsNodeEmptyStub;
  HoudiniApi::ParmInfo_IsNonValue = &HoudiniApi::ParmInfo_IsNonValueEmptyStub;
  HoudiniApi::ParmInfo_GetIntValueCount = &HoudiniApi::ParmInfo_GetIntValueCountEmptyStub;
  HoudiniApi::ParmInfo_GetFloatValueCount = &HoudiniApi::ParmInfo_GetFloatValueCountEmptyStub;
  HoudiniApi::ParmInfo_GetStringValueCount = &HoudiniApi::ParmInfo_GetStringValueCountEmptyStub;
  HoudiniApi::ParmChoiceInfo_Init = &HoudiniApi::ParmChoiceInfo_InitEmptyStub;
  HoudiniApi::ParmChoiceInfo_Create = &HoudiniApi::ParmChoiceInfo_CreateEmptyStub;
  HoudiniApi::HandleInfo_Init = &HoudiniApi::HandleInfo_InitEmptyStub;
  HoudiniApi::HandleInfo_Create = &HoudiniApi::HandleInfo_CreateEmptyStub;
  HoudiniApi::HandleBindingInfo_Init = &HoudiniApi::HandleBindingInfo_InitEmptyStub;
  HoudiniApi::HandleBindingInfo_Create = &HoudiniApi::HandleBindingInfo_CreateEmptyStub;
  HoudiniApi::ObjectInfo_Init = &HoudiniApi::ObjectInfo_InitEmptyStub;
  HoudiniApi::ObjectInfo_Create = &HoudiniApi::ObjectInfo_CreateEmptyStub;
  HoudiniApi::GeoInfo_Init = &HoudiniApi::GeoInfo_InitEmptyStub;
  HoudiniApi::GeoInfo_Create = &HoudiniApi::GeoInfo_CreateEmptyStub;
  HoudiniApi::GeoInfo_GetGroupCountByType = &HoudiniApi::GeoInfo_GetGroupCountByTypeEmptyStub;
  HoudiniApi::PartInfo_Init = &HoudiniApi::PartInfo_InitEmptyStub;
  HoudiniApi::PartInfo_Create = &HoudiniApi::PartInfo_CreateEmptyStub;
  HoudiniApi::PartInfo_GetElementCountByAttributeOwner = &HoudiniApi::PartInfo_GetElementCountByAttributeOwnerEmptyStub;
  HoudiniApi::PartInfo_GetElementCountByGroupType = &HoudiniApi::PartInfo_GetElementCountByGroupTypeEmptyStub;
  HoudiniApi::PartInfo_GetAttributeCountByOwner = &HoudiniApi::PartInfo_GetAttributeCountByOwnerEmptyStub;
  HoudiniApi::AttributeInfo_Init = &HoudiniApi::AttributeInfo_InitEmptyStub;
  HoudiniApi::AttributeInfo_Create = &HoudiniApi::AttributeInfo_CreateEmptyStub;
  HoudiniApi::MaterialInfo_Init = &HoudiniApi::MaterialInfo_InitEmptyStub;
  HoudiniApi::MaterialInfo_Create = &HoudiniApi::MaterialInfo_CreateEmptyStub;
  HoudiniApi::ImageFileFormat_Init = &HoudiniApi::ImageFileFormat_InitEmptyStub;
  HoudiniApi::ImageFileFormat_Create = &HoudiniApi::ImageFileFormat_CreateEmptyStub;
  HoudiniApi::ImageInfo_Init = &HoudiniApi::ImageInfo_InitEmptyStub;
  HoudiniApi::ImageInfo_Create = &HoudiniApi::ImageInfo_CreateEmptyStub;
  HoudiniApi::Keyframe_Init = &HoudiniApi::Keyframe_InitEmptyStub;
  HoudiniApi::Keyframe_Create = &HoudiniApi::Keyframe_CreateEmptyStub;
  HoudiniApi::VolumeInfo_Init = &HoudiniApi::VolumeInfo_InitEmptyStub;
  HoudiniApi::VolumeInfo_Create = &HoudiniApi::VolumeInfo_CreateEmptyStub;
  HoudiniApi::VolumeTileInfo_Init = &HoudiniApi::VolumeTileInfo_InitEmptyStub;
  HoudiniApi::VolumeTileInfo_Create = &HoudiniApi::VolumeTileInfo_CreateEmptyStub;
  HoudiniApi::CurveInfo_Init = &HoudiniApi::CurveInfo_InitEmptyStub;
  HoudiniApi::CurveInfo_Create = &HoudiniApi::CurveInfo_CreateEmptyStub;
  HoudiniApi::InputCurveInfo_Init = &HoudiniApi::InputCurveInfo_InitEmptyStub;
  HoudiniApi::InputCurveInfo_Create = &HoudiniApi::InputCurveInfo_CreateEmptyStub;
  HoudiniApi::Transform_Init = &HoudiniApi::Transform_InitEmptyStub;
  HoudiniApi::Transform_Create = &HoudiniApi::Transform_CreateEmptyStub;
  HoudiniApi::TransformEuler_Init = &HoudiniApi::TransformEuler_InitEmptyStub;
  HoudiniApi::TransformEuler_Create = &HoudiniApi::TransformEuler_CreateEmptyStub;
  HoudiniApi::Viewport_Init = &HoudiniApi::Viewport_InitEmptyStub;
  HoudiniApi::Viewport_Create = &HoudiniApi::Viewport_CreateEmptyStub;
  HoudiniApi::SessionSyncInfo_Init = &HoudiniApi::SessionSyncInfo_InitEmptyStub;
  HoudiniApi::SessionSyncInfo_Create = &HoudiniApi::SessionSyncInfo_CreateEmptyStub;

}


bool
HoudiniApi::is_hapi_initialized()
{
	return ( HoudiniApi::IsInitialized != &HoudiniApi::IsInitializedEmptyStub );
}

    


HAPI_Result
HoudiniApi::CreateInProcessSessionEmptyStub(HAPI_Session * session, const HAPI_SessionInfo * session_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::StartThriftSocketServerEmptyStub(const HAPI_ThriftServerOptions * options, int port, HAPI_ProcessId * process_id, const char * log_file)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::CreateThriftSocketSessionEmptyStub(HAPI_Session * session, const char * host_name, int port, const HAPI_SessionInfo * session_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::StartThriftNamedPipeServerEmptyStub(const HAPI_ThriftServerOptions * options, const char * pipe_name, HAPI_ProcessId * process_id, const char * log_file)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::CreateThriftNamedPipeSessionEmptyStub(HAPI_Session * session, const char * pipe_name, const HAPI_SessionInfo * session_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::StartThriftSharedMemoryServerEmptyStub(const HAPI_ThriftServerOptions * options, const char * shared_mem_name, HAPI_ProcessId * process_id, const char * log_file)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::CreateThriftSharedMemorySessionEmptyStub(HAPI_Session * session, const char * shared_mem_name, const HAPI_SessionInfo * session_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::BindCustomImplementationEmptyStub(HAPI_SessionType session_type, const char * dll_path)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::CreateCustomSessionEmptyStub(HAPI_SessionType session_type, void * session_info, HAPI_Session * session)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::IsSessionValidEmptyStub(const HAPI_Session * session)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::CloseSessionEmptyStub(const HAPI_Session * session)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::IsInitializedEmptyStub(const HAPI_Session * session)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::InitializeEmptyStub(const HAPI_Session * session, const HAPI_CookOptions * cook_options, HAPI_Bool use_cooking_thread, int cooking_thread_stack_size, const char * houdini_environment_files, const char * otl_search_path, const char * dso_search_path, const char * image_dso_search_path, const char * audio_dso_search_path)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::CleanupEmptyStub(const HAPI_Session * session)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::ShutdownEmptyStub(const HAPI_Session * session)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::StartPerformanceMonitorProfileEmptyStub(const HAPI_Session * session, const char * title, int * profile_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::StopPerformanceMonitorProfileEmptyStub(const HAPI_Session * session, int profile_id, const char * file_path)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetEnvIntEmptyStub(HAPI_EnvIntType int_type, int * value)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetSessionEnvIntEmptyStub(const HAPI_Session * session, HAPI_SessionEnvIntType int_type, int * value)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetServerEnvIntEmptyStub(const HAPI_Session * session, const char * variable_name, int * value)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetServerEnvStringEmptyStub(const HAPI_Session * session, const char * variable_name, HAPI_StringHandle * value)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetServerEnvVarCountEmptyStub(const HAPI_Session * session, int * env_count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetServerEnvVarListEmptyStub(const HAPI_Session * session, HAPI_StringHandle * values_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetServerEnvIntEmptyStub(const HAPI_Session * session, const char * variable_name, int value)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetServerEnvStringEmptyStub(const HAPI_Session * session, const char * variable_name, const char * value)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetStatusEmptyStub(const HAPI_Session * session, HAPI_StatusType status_type, int * status)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetStatusStringBufLengthEmptyStub(const HAPI_Session * session, HAPI_StatusType status_type, HAPI_StatusVerbosity verbosity, int * buffer_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetStatusStringEmptyStub(const HAPI_Session * session, HAPI_StatusType status_type, char * string_value, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::ComposeNodeCookResultEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_StatusVerbosity verbosity, int * buffer_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetComposedNodeCookResultEmptyStub(const HAPI_Session * session, char * string_value, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetNodeCookResultLengthEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_StatusVerbosity verbosity, int * buffer_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetNodeCookResultEmptyStub(const HAPI_Session * session, char * string_value, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetMessageNodeCountEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, int * count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetMessageNodeIdsEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_NodeId * message_node_ids_array, int count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::CheckForSpecificErrorsEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_ErrorCodeBits errors_to_look_for, HAPI_ErrorCodeBits * errors_found)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::ClearConnectionErrorEmptyStub()
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetConnectionErrorLengthEmptyStub(int * buffer_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetConnectionErrorEmptyStub(char * string_value, int length, HAPI_Bool clear)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetCookingTotalCountEmptyStub(const HAPI_Session * session, int * count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetCookingCurrentCountEmptyStub(const HAPI_Session * session, int * count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::InterruptEmptyStub(const HAPI_Session * session)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::ConvertTransformEmptyStub(const HAPI_Session * session, const HAPI_TransformEuler * transform_in, HAPI_RSTOrder rst_order, HAPI_XYZOrder rot_order, HAPI_TransformEuler * transform_out)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::ConvertMatrixToQuatEmptyStub(const HAPI_Session * session, const float * matrix, HAPI_RSTOrder rst_order, HAPI_Transform * transform_out)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::ConvertMatrixToEulerEmptyStub(const HAPI_Session * session, const float * matrix, HAPI_RSTOrder rst_order, HAPI_XYZOrder rot_order, HAPI_TransformEuler * transform_out)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::ConvertTransformQuatToMatrixEmptyStub(const HAPI_Session * session, const HAPI_Transform * transform, float * matrix)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::ConvertTransformEulerToMatrixEmptyStub(const HAPI_Session * session, const HAPI_TransformEuler * transform, float * matrix)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::PythonThreadInterpreterLockEmptyStub(const HAPI_Session * session, HAPI_Bool locked)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetStringBufLengthEmptyStub(const HAPI_Session * session, HAPI_StringHandle string_handle, int * buffer_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetStringEmptyStub(const HAPI_Session * session, HAPI_StringHandle string_handle, char * string_value, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetCustomStringEmptyStub(const HAPI_Session * session, const char * string_value, HAPI_StringHandle * handle_value)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::RemoveCustomStringEmptyStub(const HAPI_Session * session, const HAPI_StringHandle string_handle)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetStringBatchSizeEmptyStub(const HAPI_Session * session, const int * string_handle_array, int string_handle_count, int * string_buffer_size)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetStringBatchEmptyStub(const HAPI_Session * session, char * char_buffer, int char_array_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetTimeEmptyStub(const HAPI_Session * session, float * time)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetTimeEmptyStub(const HAPI_Session * session, float time)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetUseHoudiniTimeEmptyStub(const HAPI_Session * session, HAPI_Bool * enabled)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetUseHoudiniTimeEmptyStub(const HAPI_Session * session, HAPI_Bool enabled)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetTimelineOptionsEmptyStub(const HAPI_Session * session, HAPI_TimelineOptions * timeline_options)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetTimelineOptionsEmptyStub(const HAPI_Session * session, const HAPI_TimelineOptions * timeline_options)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetCompositorOptionsEmptyStub(const HAPI_Session * session, HAPI_CompositorOptions * compositor_options)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetCompositorOptionsEmptyStub(const HAPI_Session * session, const HAPI_CompositorOptions * compositor_options)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::LoadAssetLibraryFromFileEmptyStub(const HAPI_Session * session, const char * file_path, HAPI_Bool allow_overwrite, HAPI_AssetLibraryId * library_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::LoadAssetLibraryFromMemoryEmptyStub(const HAPI_Session * session, const char * library_buffer, int library_buffer_length, HAPI_Bool allow_overwrite, HAPI_AssetLibraryId * library_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAvailableAssetCountEmptyStub(const HAPI_Session * session, HAPI_AssetLibraryId library_id, int * asset_count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAvailableAssetsEmptyStub(const HAPI_Session * session, HAPI_AssetLibraryId library_id, HAPI_StringHandle * asset_names_array, int asset_count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAssetInfoEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_AssetInfo * asset_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAssetDefinitionParmCountsEmptyStub(const HAPI_Session * session, HAPI_AssetLibraryId library_id, const char * asset_name, int * parm_count, int * int_value_count, int * float_value_count, int * string_value_count, int * choice_value_count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAssetDefinitionParmInfosEmptyStub(const HAPI_Session * session, HAPI_AssetLibraryId library_id, const char * asset_name, HAPI_ParmInfo * parm_infos_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAssetDefinitionParmValuesEmptyStub(const HAPI_Session * session, HAPI_AssetLibraryId library_id, const char * asset_name, int * int_values_array, int int_start, int int_length, float * float_values_array, int float_start, int float_length, HAPI_Bool string_evaluate, HAPI_StringHandle * string_values_array, int string_start, int string_length, HAPI_ParmChoiceInfo * choice_values_array, int choice_start, int choice_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAssetDefinitionParmTagNameEmptyStub(const HAPI_Session * session, HAPI_AssetLibraryId library_id, const char * asset_name, HAPI_ParmId parm_id, int tag_index, HAPI_StringHandle * tag_name)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAssetDefinitionParmTagValueEmptyStub(const HAPI_Session * session, HAPI_AssetLibraryId library_id, const char * asset_name, HAPI_ParmId parm_id, const char * tag_name, HAPI_StringHandle * tag_value)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetLoadedAssetLibraryCountEmptyStub(const HAPI_Session * session, int * count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAssetLibraryIdsEmptyStub(const HAPI_Session * session, HAPI_AssetLibraryId * asset_library_ids_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAssetLibraryFilePathEmptyStub(const HAPI_Session * session, HAPI_AssetLibraryId asset_library_id, HAPI_StringHandle * file_path_sh)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::LoadHIPFileEmptyStub(const HAPI_Session * session, const char * file_name, HAPI_Bool cook_on_load)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::MergeHIPFileEmptyStub(const HAPI_Session * session, const char * file_name, HAPI_Bool cook_on_load, HAPI_HIPFileId * file_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SaveHIPFileEmptyStub(const HAPI_Session * session, const char * file_path, HAPI_Bool lock_nodes)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetHIPFileNodeCountEmptyStub(const HAPI_Session * session, HAPI_HIPFileId id, int * count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetHIPFileNodeIdsEmptyStub(const HAPI_Session * session, HAPI_HIPFileId id, HAPI_NodeId * node_ids, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::IsNodeValidEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, int unique_node_id, HAPI_Bool * answer)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetNodeInfoEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_NodeInfo * node_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetNodePathEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_NodeId relative_to_node_id, HAPI_StringHandle * path)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetManagerNodeIdEmptyStub(const HAPI_Session * session, HAPI_NodeType node_type, HAPI_NodeId * node_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::ComposeChildNodeListEmptyStub(const HAPI_Session * session, HAPI_NodeId parent_node_id, HAPI_NodeTypeBits node_type_filter, HAPI_NodeFlagsBits node_flags_filter, HAPI_Bool recursive, int * count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetComposedChildNodeListEmptyStub(const HAPI_Session * session, HAPI_NodeId parent_node_id, HAPI_NodeId * child_node_ids_array, int count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::CreateNodeEmptyStub(const HAPI_Session * session, HAPI_NodeId parent_node_id, const char * operator_name, const char * node_label, HAPI_Bool cook_on_creation, HAPI_NodeId * new_node_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::CreateInputNodeEmptyStub(const HAPI_Session * session, HAPI_NodeId parent_node_id, HAPI_NodeId * node_id, const char * name)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::CreateInputCurveNodeEmptyStub(const HAPI_Session * session, HAPI_NodeId parent_node_id, HAPI_NodeId * node_id, const char * name)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::CreateHeightFieldInputEmptyStub(const HAPI_Session * session, HAPI_NodeId parent_node_id, const char * name, int xsize, int ysize, float voxelsize, HAPI_HeightFieldSampling sampling, HAPI_NodeId * heightfield_node_id, HAPI_NodeId * height_node_id, HAPI_NodeId * mask_node_id, HAPI_NodeId * merge_node_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::CreateHeightfieldInputVolumeNodeEmptyStub(const HAPI_Session * session, HAPI_NodeId parent_node_id, HAPI_NodeId * new_node_id, const char * name, int xsize, int ysize, float voxelsize)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::CookNodeEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const HAPI_CookOptions * cook_options)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::DeleteNodeEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::RenameNodeEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const char * new_name)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::ConnectNodeInputEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, int input_index, HAPI_NodeId node_id_to_connect, int output_index)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::DisconnectNodeInputEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, int input_index)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::QueryNodeInputEmptyStub(const HAPI_Session * session, HAPI_NodeId node_to_query, int input_index, HAPI_NodeId * connected_node_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetNodeInputNameEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, int input_idx, HAPI_StringHandle * name)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::DisconnectNodeOutputsAtEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, int output_index)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::QueryNodeOutputConnectedCountEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, int output_idx, HAPI_Bool into_subnets, HAPI_Bool through_dots, int * connected_count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::QueryNodeOutputConnectedNodesEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, int output_idx, HAPI_Bool into_subnets, HAPI_Bool through_dots, HAPI_NodeId * connected_node_ids_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetNodeOutputNameEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, int output_idx, HAPI_StringHandle * name)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetNodeFromPathEmptyStub(const HAPI_Session * session, const HAPI_NodeId parent_node_id, const char * path, HAPI_NodeId * node_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetOutputNodeIdEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, int output, HAPI_NodeId * output_node_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetParametersEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_ParmInfo * parm_infos_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetParmInfoEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_ParmId parm_id, HAPI_ParmInfo * parm_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetParmIdFromNameEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const char * parm_name, HAPI_ParmId * parm_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetParmInfoFromNameEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const char * parm_name, HAPI_ParmInfo * parm_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetParmTagNameEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_ParmId parm_id, int tag_index, HAPI_StringHandle * tag_name)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetParmTagValueEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_ParmId parm_id, const char * tag_name, HAPI_StringHandle * tag_value)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::ParmHasTagEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_ParmId parm_id, const char * tag_name, HAPI_Bool * has_tag)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::ParmHasExpressionEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const char * parm_name, int index, HAPI_Bool * has_expression)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetParmWithTagEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const char * tag_name, HAPI_ParmId * parm_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetParmExpressionEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const char * parm_name, int index, HAPI_StringHandle * value)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::RevertParmToDefaultEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const char * parm_name, int index)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::RevertParmToDefaultsEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const char * parm_name)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetParmExpressionEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const char * value, HAPI_ParmId parm_id, int index)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::RemoveParmExpressionEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_ParmId parm_id, int index)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetParmIntValueEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const char * parm_name, int index, int * value)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetParmIntValuesEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, int * values_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetParmFloatValueEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const char * parm_name, int index, float * value)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetParmFloatValuesEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, float * values_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetParmStringValueEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const char * parm_name, int index, HAPI_Bool evaluate, HAPI_StringHandle * value)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetParmStringValuesEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_Bool evaluate, HAPI_StringHandle * values_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetParmNodeValueEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const char * parm_name, HAPI_NodeId * value)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetParmFileEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const char * parm_name, const char * destination_directory, const char * destination_file_name)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetParmChoiceListsEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_ParmChoiceInfo * parm_choices_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetParmIntValueEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const char * parm_name, int index, int value)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetParmIntValuesEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const int * values_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetParmFloatValueEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const char * parm_name, int index, float value)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetParmFloatValuesEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const float * values_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetParmStringValueEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const char * value, HAPI_ParmId parm_id, int index)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetParmNodeValueEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const char * parm_name, HAPI_NodeId value)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::InsertMultiparmInstanceEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_ParmId parm_id, int instance_position)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::RemoveMultiparmInstanceEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_ParmId parm_id, int instance_position)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetHandleInfoEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_HandleInfo * handle_infos_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetHandleBindingInfoEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, int handle_index, HAPI_HandleBindingInfo * handle_binding_infos_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetPresetBufLengthEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PresetType preset_type, const char * preset_name, int * buffer_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetPresetEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, char * buffer, int buffer_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetPresetEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PresetType preset_type, const char * preset_name, const char * buffer, int buffer_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetPresetCountEmptyStub(const HAPI_Session * session, const char * buffer, int buffer_length, int * count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetPresetNamesEmptyStub(const HAPI_Session * session, const char * buffer, int buffer_length, HAPI_StringHandle * preset_names_array, int preset_names_count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetObjectInfoEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_ObjectInfo * object_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetObjectTransformEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_NodeId relative_to_node_id, HAPI_RSTOrder rst_order, HAPI_Transform * transform)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::ComposeObjectListEmptyStub(const HAPI_Session * session, HAPI_NodeId parent_node_id, const char * categories, int * object_count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetComposedObjectListEmptyStub(const HAPI_Session * session, HAPI_NodeId parent_node_id, HAPI_ObjectInfo * object_infos_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetComposedObjectTransformsEmptyStub(const HAPI_Session * session, HAPI_NodeId parent_node_id, HAPI_RSTOrder rst_order, HAPI_Transform * transform_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetInstancedObjectIdsEmptyStub(const HAPI_Session * session, HAPI_NodeId object_node_id, HAPI_NodeId * instanced_node_id_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetInstanceTransformsOnPartEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, HAPI_RSTOrder rst_order, HAPI_Transform * transforms_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetObjectTransformEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const HAPI_TransformEuler * trans)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetDisplayGeoInfoEmptyStub(const HAPI_Session * session, HAPI_NodeId object_node_id, HAPI_GeoInfo * geo_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetOutputGeoCountEmptyStub(const HAPI_Session* session, HAPI_NodeId node_id, int* count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetOutputGeoInfosEmptyStub(const HAPI_Session* session, HAPI_NodeId node_id, HAPI_GeoInfo* geo_infos_array, int count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetGeoInfoEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_GeoInfo * geo_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetPartInfoEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, HAPI_PartInfo * part_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetEdgeCountOfEdgeGroupEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * group_name, int * edge_count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetFaceCountsEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, int * face_counts_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetVertexListEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, int * vertex_list_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeInfoEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeOwner owner, HAPI_AttributeInfo * attr_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeNamesEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, HAPI_AttributeOwner owner, HAPI_StringHandle * attribute_names_array, int count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeIntDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeInfo * attr_info, int stride, int * data_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeIntArrayDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeInfo * attr_info, int * data_fixed_array, int data_fixed_length, int * sizes_fixed_array, int start, int sizes_fixed_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeUInt8DataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeInfo * attr_info, int stride, HAPI_UInt8 * data_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeUInt8ArrayDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeInfo * attr_info, HAPI_UInt8 * data_fixed_array, int data_fixed_length, int * sizes_fixed_array, int start, int sizes_fixed_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeInt8DataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeInfo * attr_info, int stride, HAPI_Int8 * data_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeInt8ArrayDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeInfo * attr_info, HAPI_Int8 * data_fixed_array, int data_fixed_length, int * sizes_fixed_array, int start, int sizes_fixed_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeInt16DataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeInfo * attr_info, int stride, HAPI_Int16 * data_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeInt16ArrayDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeInfo * attr_info, HAPI_Int16 * data_fixed_array, int data_fixed_length, int * sizes_fixed_array, int start, int sizes_fixed_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeInt64DataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeInfo * attr_info, int stride, HAPI_Int64 * data_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeInt64ArrayDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeInfo * attr_info, HAPI_Int64 * data_fixed_array, int data_fixed_length, int * sizes_fixed_array, int start, int sizes_fixed_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeFloatDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeInfo * attr_info, int stride, float * data_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeFloatArrayDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeInfo * attr_info, float * data_fixed_array, int data_fixed_length, int * sizes_fixed_array, int start, int sizes_fixed_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeFloat64DataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeInfo * attr_info, int stride, double * data_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeFloat64ArrayDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeInfo * attr_info, double * data_fixed_array, int data_fixed_length, int * sizes_fixed_array, int start, int sizes_fixed_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeStringDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeInfo * attr_info, HAPI_StringHandle * data_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeStringArrayDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeInfo * attr_info, HAPI_StringHandle * data_fixed_array, int data_fixed_length, int * sizes_fixed_array, int start, int sizes_fixed_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeDictionaryDataEmptyStub(const HAPI_Session* session, HAPI_NodeId node_id, HAPI_PartId part_id, const char* name, HAPI_AttributeInfo* attr_info, HAPI_StringHandle* data_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeDictionaryArrayDataEmptyStub(const HAPI_Session* session, HAPI_NodeId node_id, HAPI_PartId part_id, const char* name, HAPI_AttributeInfo* attr_info, HAPI_StringHandle* data_fixed_array, int data_fixed_length, int* sizes_fixed_array, int start, int sizes_fixed_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeIntDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeInfo * attr_info, int stride, int * data_array, int start, int length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeUInt8DataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeInfo * attr_info, int stride, HAPI_UInt8 * data_array, int start, int length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeInt8DataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeInfo * attr_info, int stride, HAPI_Int8 * data_array, int start, int length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeInt16DataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeInfo * attr_info, int stride, HAPI_Int16 * data_array, int start, int length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeInt64DataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeInfo * attr_info, int stride, HAPI_Int64 * data_array, int start, int length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeFloatDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeInfo * attr_info, int stride, float * data_array, int start, int length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeFloat64DataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeInfo * attr_info, int stride, double * data_array, int start, int length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeStringDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeInfo * attr_info, HAPI_StringHandle * data_array, int start, int length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeDictionaryDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, HAPI_AttributeInfo * attr_info, HAPI_StringHandle * data_array, int start, int length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeIntArrayDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * attr_name, HAPI_AttributeInfo * attr_info, int * data_fixed_array, int data_fixed_length, int * sizes_fixed_array, int start, int sizes_fixed_length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeUInt8ArrayDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * attr_name, HAPI_AttributeInfo * attr_info, HAPI_UInt8 * data_fixed_array, int data_fixed_length, int * sizes_fixed_array, int start, int sizes_fixed_length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeInt8ArrayDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * attr_name, HAPI_AttributeInfo * attr_info, HAPI_Int8 * data_fixed_array, int data_fixed_length, int * sizes_fixed_array, int start, int sizes_fixed_length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeInt16ArrayDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * attr_name, HAPI_AttributeInfo * attr_info, HAPI_Int16 * data_fixed_array, int data_fixed_length, int * sizes_fixed_array, int start, int sizes_fixed_length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeInt64ArrayDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * attr_name, HAPI_AttributeInfo * attr_info, HAPI_Int64 * data_fixed_array, int data_fixed_length, int * sizes_fixed_array, int start, int sizes_fixed_length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeFloatArrayDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * attr_name, HAPI_AttributeInfo * attr_info, float * data_fixed_array, int data_fixed_length, int * sizes_fixed_array, int start, int sizes_fixed_length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeFloat64ArrayDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * attr_name, HAPI_AttributeInfo * attr_info, double * data_fixed_array, int data_fixed_length, int * sizes_fixed_array, int start, int sizes_fixed_length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeStringArrayDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * attr_name, HAPI_AttributeInfo * attr_info, HAPI_StringHandle * data_fixed_array, int data_fixed_length, int * sizes_fixed_array, int start, int sizes_fixed_length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetAttributeDictionaryArrayDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * attr_name, HAPI_AttributeInfo * attr_info, HAPI_StringHandle * data_fixed_array, int data_fixed_length, int * sizes_fixed_array, int start, int sizes_fixed_length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetJobStatusEmptyStub(const HAPI_Session * session, int job_id, HAPI_JobStatus * job_status)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetGroupNamesEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_GroupType group_type, HAPI_StringHandle * group_names_array, int group_count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetGroupMembershipEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, HAPI_GroupType group_type, const char * group_name, HAPI_Bool * membership_array_all_equal, int * membership_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetGroupCountOnPackedInstancePartEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, int * pointGroupCount, int * primitiveGroupCount)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetGroupNamesOnPackedInstancePartEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, HAPI_GroupType group_type, HAPI_StringHandle * group_names_array, int group_count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetGroupMembershipOnPackedInstancePartEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, HAPI_GroupType group_type, const char * group_name, HAPI_Bool * membership_array_all_equal, int * membership_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetInstancedPartIdsEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, HAPI_PartId * instanced_parts_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetInstancerPartTransformsEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, HAPI_RSTOrder rst_order, HAPI_Transform * transforms_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetPartInfoEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const HAPI_PartInfo * part_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetFaceCountsEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const int * face_counts_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetVertexListEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const int * vertex_list_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::AddAttributeEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::DeleteAttributeEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeIntDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const int * data_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeUInt8DataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const HAPI_UInt8 * data_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeInt8DataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const HAPI_Int8 * data_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeInt16DataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const HAPI_Int16 * data_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeInt64DataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const HAPI_Int64 * data_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeFloatDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const float * data_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeFloat64DataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const double * data_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeStringDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const char ** data_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeIndexedStringDataEmptyStub(const HAPI_Session* session, HAPI_NodeId node_id, HAPI_PartId part_id, const char* name, const HAPI_AttributeInfo* attr_info, const char** string_array, int string_count, const int* indices_array, int indices_start, int indices_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeStringUniqueDataEmptyStub(const HAPI_Session* session, HAPI_NodeId node_id, HAPI_PartId part_id, const char* name, const HAPI_AttributeInfo* attr_info, const char* data_array, int data_length, int start_index, int num_indices)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeIntUniqueDataEmptyStub(const HAPI_Session* session, HAPI_NodeId node_id, HAPI_PartId part_id, const char* name, const HAPI_AttributeInfo* attr_info, const int* data_array, int data_length, int start_index, int num_indices)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeUInt8UniqueDataEmptyStub(const HAPI_Session* session, HAPI_NodeId node_id, HAPI_PartId part_id, const char* name, const HAPI_AttributeInfo* attr_info, const HAPI_UInt8* data_array, int data_length, int start_index, int num_indices)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeInt8UniqueDataEmptyStub(const HAPI_Session* session, HAPI_NodeId node_id, HAPI_PartId part_id, const char* name, const HAPI_AttributeInfo* attr_info, const HAPI_Int8* data_array, int data_length, int start_index, int num_indices)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeInt16UniqueDataEmptyStub(const HAPI_Session* session, HAPI_NodeId node_id, HAPI_PartId part_id, const char* name, const HAPI_AttributeInfo* attr_info, const HAPI_Int16* data_array, int data_length, int start_index, int num_indices)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeInt64UniqueDataEmptyStub(const HAPI_Session* session, HAPI_NodeId node_id, HAPI_PartId part_id, const char* name, const HAPI_AttributeInfo* attr_info, const HAPI_Int64* data_array, int data_length, int start_index, int num_indices)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeFloatUniqueDataEmptyStub(const HAPI_Session* session, HAPI_NodeId node_id, HAPI_PartId part_id, const char* name, const HAPI_AttributeInfo* attr_info, const float* data_array, int data_length, int start_index, int num_indices)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeFloat64UniqueDataEmptyStub(const HAPI_Session* session, HAPI_NodeId node_id, HAPI_PartId part_id, const char* name, const HAPI_AttributeInfo* attr_info, const double* data_array, int data_length, int start_index, int num_indices)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeDictionaryDataEmptyStub(const HAPI_Session* session, HAPI_NodeId node_id, HAPI_PartId part_id, const char* name, const HAPI_AttributeInfo* attr_info, const char** data_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeIntArrayDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const int * data_fixed_array, int data_fixed_length, const int * sizes_fixed_array, int start, int sizes_fixed_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeUInt8ArrayDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const HAPI_UInt8 * data_fixed_array, int data_fixed_length, const int * sizes_fixed_array, int start, int sizes_fixed_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeInt8ArrayDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const HAPI_Int8 * data_fixed_array, int data_fixed_length, const int * sizes_fixed_array, int start, int sizes_fixed_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeInt16ArrayDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const HAPI_Int16 * data_fixed_array, int data_fixed_length, const int * sizes_fixed_array, int start, int sizes_fixed_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeInt64ArrayDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const HAPI_Int64 * data_fixed_array, int data_fixed_length, const int * sizes_fixed_array, int start, int sizes_fixed_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeFloatArrayDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const float * data_fixed_array, int data_fixed_length, const int * sizes_fixed_array, int start, int sizes_fixed_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeFloat64ArrayDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const double * data_fixed_array, int data_fixed_length, const int * sizes_fixed_array, int start, int sizes_fixed_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeStringArrayDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const char ** data_fixed_array, int data_fixed_length, const int * sizes_fixed_array, int start, int sizes_fixed_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeDictionaryArrayDataEmptyStub(const HAPI_Session* session, HAPI_NodeId node_id, HAPI_PartId part_id, const char* name, const HAPI_AttributeInfo* attr_info, const char** data_fixed_array, int data_fixed_length, const int* sizes_fixed_array, int start, int sizes_fixed_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeIntDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const int * data_array, int start, int length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeUInt8DataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const HAPI_UInt8 * data_array, int start, int length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeInt8DataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const HAPI_Int8 * data_array, int start, int length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeInt16DataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const HAPI_Int16 * data_array, int start, int length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeInt64DataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const HAPI_Int64 * data_array, int start, int length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeFloatDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const float * data_array, int start, int length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeFloat64DataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const double * data_array, int start, int length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeStringDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const char ** data_array, int start, int length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeIndexedStringDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const char ** string_array, int string_count, const int * indices_array, int indices_start, int indices_length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeStringUniqueDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const char * data_array, int data_length, int start_index, int num_indices, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeIntUniqueDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const int * data_array, int data_length, int start_index, int num_indices, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeUInt8UniqueDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const HAPI_UInt8 * data_array, int data_length, int start_index, int num_indices, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeInt8UniqueDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const HAPI_Int8* data_array, int data_length, int start_index, int num_indices, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeInt16UniqueDataAsyncEmptyStub(const HAPI_Session* session, HAPI_NodeId node_id, HAPI_PartId part_id, const char* name, const HAPI_AttributeInfo* attr_info, const HAPI_Int16* data_array, int data_length, int start_index, int num_indices, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeInt64UniqueDataAsyncEmptyStub(const HAPI_Session* session, HAPI_NodeId node_id, HAPI_PartId part_id, const char* name, const HAPI_AttributeInfo* attr_info, const HAPI_Int64* data_array, int data_length, int start_index, int num_indices, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeFloatUniqueDataAsyncEmptyStub(const HAPI_Session* session, HAPI_NodeId node_id, HAPI_PartId part_id, const char* name, const HAPI_AttributeInfo* attr_info, const float* data_array, int data_length, int start_index, int num_indices, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeFloat64UniqueDataAsyncEmptyStub(const HAPI_Session* session, HAPI_NodeId node_id, HAPI_PartId part_id, const char* name, const HAPI_AttributeInfo* attr_info, const double* data_array, int data_length, int start_index, int num_indices, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeDictionaryDataAsyncEmptyStub(const HAPI_Session* session, HAPI_NodeId node_id, HAPI_PartId part_id, const char* name, const HAPI_AttributeInfo* attr_info, const char** data_array, int start, int length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeIntArrayDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const int * data_fixed_array, int data_fixed_length, const int * sizes_fixed_array, int start, int sizes_fixed_length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeUInt8ArrayDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const HAPI_UInt8 * data_fixed_array, int data_fixed_length, const int * sizes_fixed_array, int start, int sizes_fixed_length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeInt8ArrayDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const HAPI_Int8 * data_fixed_array, int data_fixed_length, const int * sizes_fixed_array, int start, int sizes_fixed_length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeInt16ArrayDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const HAPI_Int16 * data_fixed_array, int data_fixed_length, const int * sizes_fixed_array, int start, int sizes_fixed_length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeInt64ArrayDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const HAPI_Int64 * data_fixed_array, int data_fixed_length, const int * sizes_fixed_array, int start, int sizes_fixed_length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeFloatArrayDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const float * data_fixed_array, int data_fixed_length, const int * sizes_fixed_array, int start, int sizes_fixed_length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeFloat64ArrayDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const double * data_fixed_array, int data_fixed_length, const int * sizes_fixed_array, int start, int sizes_fixed_length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeStringArrayDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const char ** data_fixed_array, int data_fixed_length, const int * sizes_fixed_array, int start, int sizes_fixed_length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAttributeDictionaryArrayDataAsyncEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const HAPI_AttributeInfo * attr_info, const char ** data_fixed_array, int data_fixed_length, const int * sizes_fixed_array, int start, int sizes_fixed_length, int * job_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::AddGroupEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, HAPI_GroupType group_type, const char * group_name)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::DeleteGroupEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, HAPI_GroupType group_type, const char * group_name)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetGroupMembershipEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, HAPI_GroupType group_type, const char * group_name, const int * membership_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::CommitGeoEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::RevertGeoEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetMaterialNodeIdsOnFacesEmptyStub(const HAPI_Session * session, HAPI_NodeId geometry_node_id, HAPI_PartId part_id, HAPI_Bool * are_all_the_same, HAPI_NodeId * material_ids_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetMaterialInfoEmptyStub(const HAPI_Session * session, HAPI_NodeId material_node_id, HAPI_MaterialInfo * material_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::RenderCOPToImageEmptyStub(const HAPI_Session * session, HAPI_NodeId cop_node_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::RenderTextureToImageEmptyStub(const HAPI_Session * session, HAPI_NodeId material_node_id, HAPI_ParmId parm_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetImageInfoEmptyStub(const HAPI_Session * session, HAPI_NodeId material_node_id, HAPI_ImageInfo * image_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetImageInfoEmptyStub(const HAPI_Session * session, HAPI_NodeId material_node_id, const HAPI_ImageInfo * image_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetImagePlaneCountEmptyStub(const HAPI_Session * session, HAPI_NodeId material_node_id, int * image_plane_count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetImagePlanesEmptyStub(const HAPI_Session * session, HAPI_NodeId material_node_id, HAPI_StringHandle * image_planes_array, int image_plane_count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::ExtractImageToFileEmptyStub(const HAPI_Session * session, HAPI_NodeId material_node_id, const char * image_file_format_name, const char * image_planes, const char * destination_folder_path, const char * destination_file_name, int * destination_file_path)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetImageFilePathEmptyStub(const HAPI_Session * session, HAPI_NodeId material_node_id, const char * image_file_format_name, const char * image_planes, const char * destination_folder_path, const char * destination_file_name, HAPI_ParmId texture_parm_id, int * destination_file_path)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::ExtractImageToMemoryEmptyStub(const HAPI_Session * session, HAPI_NodeId material_node_id, const char * image_file_format_name, const char * image_planes, int * buffer_size)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetImageMemoryBufferEmptyStub(const HAPI_Session * session, HAPI_NodeId material_node_id, char * buffer, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetSupportedImageFileFormatCountEmptyStub(const HAPI_Session * session, int * file_format_count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetSupportedImageFileFormatsEmptyStub(const HAPI_Session * session, HAPI_ImageFileFormat * formats_array, int file_format_count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetAnimCurveEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_ParmId parm_id, int parm_index, const HAPI_Keyframe * curve_keyframes_array, int keyframe_count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetTransformAnimCurveEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_TransformComponent trans_comp, const HAPI_Keyframe * curve_keyframes_array, int keyframe_count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::ResetSimulationEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetVolumeInfoEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, HAPI_VolumeInfo * volume_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetFirstVolumeTileEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, HAPI_VolumeTileInfo * tile)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetNextVolumeTileEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, HAPI_VolumeTileInfo * tile)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetVolumeVoxelFloatDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, int x_index, int y_index, int z_index, float * values_array, int value_count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetVolumeTileFloatDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, float fill_value, const HAPI_VolumeTileInfo * tile, float * values_array, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetVolumeVoxelIntDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, int x_index, int y_index, int z_index, int * values_array, int value_count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetVolumeTileIntDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, int fill_value, const HAPI_VolumeTileInfo * tile, int * values_array, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetHeightFieldDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, float * values_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetVolumeInfoEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const HAPI_VolumeInfo * volume_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetVolumeTileFloatDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const HAPI_VolumeTileInfo * tile, const float * values_array, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetVolumeTileIntDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const HAPI_VolumeTileInfo * tile, const int * values_array, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetVolumeVoxelFloatDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, int x_index, int y_index, int z_index, const float * values_array, int value_count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetVolumeVoxelIntDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, int x_index, int y_index, int z_index, const int * values_array, int value_count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetVolumeBoundsEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, float * x_min, float * y_min, float * z_min, float * x_max, float * y_max, float * z_max, float * x_center, float * y_center, float * z_center)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetHeightFieldDataEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const char * name, const float * values_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetVolumeVisualInfoEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, HAPI_VolumeVisualInfo * visual_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetCurveInfoEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, HAPI_CurveInfo * info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetCurveCountsEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, int * counts_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetCurveOrdersEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, int * orders_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetCurveKnotsEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, float * knots_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetCurveInfoEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const HAPI_CurveInfo * info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetCurveCountsEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const int * counts_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetCurveOrdersEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const int * orders_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetCurveKnotsEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const float * knots_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetInputCurveInfoEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, HAPI_InputCurveInfo * info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetInputCurveInfoEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PartId part_id, const HAPI_InputCurveInfo * info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetInputCurvePositionsEmptyStub(const HAPI_Session* session, HAPI_NodeId node_id, HAPI_PartId part_id, const float* positions_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetInputCurvePositionsRotationsScalesEmptyStub(const HAPI_Session* session, HAPI_NodeId node_id, HAPI_PartId part_id, const float* positions_array, int positions_start, int positions_length, const float* rotations_array, int rotations_start, int rotations_length, const float * scales_array, int scales_start, int scales_length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetBoxInfoEmptyStub(const HAPI_Session * session, HAPI_NodeId geo_node_id, HAPI_PartId part_id, HAPI_BoxInfo * box_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetSphereInfoEmptyStub(const HAPI_Session * session, HAPI_NodeId geo_node_id, HAPI_PartId part_id, HAPI_SphereInfo * sphere_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetActiveCacheCountEmptyStub(const HAPI_Session * session, int * active_cache_count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetActiveCacheNamesEmptyStub(const HAPI_Session * session, HAPI_StringHandle * cache_names_array, int active_cache_count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetCachePropertyEmptyStub(const HAPI_Session * session, const char * cache_name, HAPI_CacheProperty cache_property, int * property_value)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetCachePropertyEmptyStub(const HAPI_Session * session, const char * cache_name, HAPI_CacheProperty cache_property, int property_value)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SaveGeoToFileEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const char * file_name)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::LoadGeoFromFileEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const char * file_name)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SaveNodeToFileEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const char * file_name)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::LoadNodeFromFileEmptyStub(const HAPI_Session * session, const char * file_name, HAPI_NodeId parent_node_id, const char * node_label, HAPI_Bool cook_on_load, HAPI_NodeId * new_node_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetGeoSizeEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const char * format, int * size)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SaveGeoToMemoryEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, char * buffer, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::LoadGeoFromMemoryEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, const char * format, const char * buffer, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetNodeDisplayEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, int onOff)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetTotalCookCountEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_NodeTypeBits node_type_filter, HAPI_NodeFlagsBits node_flags_filter, HAPI_Bool recursive, int * count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetSessionSyncEmptyStub(const HAPI_Session * session, HAPI_Bool enable)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetViewportEmptyStub(const HAPI_Session * session, HAPI_Viewport * viewport)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetViewportEmptyStub(const HAPI_Session * session, const HAPI_Viewport * viewport)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetSessionSyncInfoEmptyStub(const HAPI_Session * session, HAPI_SessionSyncInfo * session_sync_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetSessionSyncInfoEmptyStub(const HAPI_Session * session, const HAPI_SessionSyncInfo * session_sync_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetPDGGraphContextsEmptyStub(const HAPI_Session * session, HAPI_StringHandle * context_names_array, HAPI_PDG_GraphContextId * context_id_array, int start, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetPDGGraphContextsCountEmptyStub(const HAPI_Session* session, int* num_contexts)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetPDGGraphContextIdEmptyStub(const HAPI_Session * session, HAPI_NodeId top_node_id, HAPI_PDG_GraphContextId * context_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::CookPDGEmptyStub(const HAPI_Session * session, HAPI_NodeId cook_node_id, int generate_only, int blocking)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::CookPDGAllOutputsEmptyStub(const HAPI_Session* session, HAPI_NodeId cook_node_id, int generate_only, int blocking)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetPDGEventsEmptyStub(const HAPI_Session * session, HAPI_PDG_GraphContextId graph_context_id, HAPI_PDG_EventInfo * event_array, int length, int * event_count, int * remaining_events)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetPDGStateEmptyStub(const HAPI_Session * session, HAPI_PDG_GraphContextId graph_context_id, int * pdg_state)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::CreateWorkItemEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PDG_WorkItemId * work_item_id, const char * name, int index)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetWorkItemInfoEmptyStub(const HAPI_Session * session, HAPI_PDG_GraphContextId graph_context_id, HAPI_PDG_WorkItemId work_item_id, HAPI_PDG_WorkItemInfo * work_item_info)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetWorkItemIntAttributeEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PDG_WorkItemId work_item_id, const char * attribute_name, const int * values_array, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetWorkItemFloatAttributeEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PDG_WorkItemId work_item_id, const char * attribute_name, const float * values_array, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::SetWorkItemStringAttributeEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PDG_WorkItemId work_item_id, const char * attribute_name, int data_index, const char * value)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::CommitWorkItemsEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetNumWorkItemsEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, int * num)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetWorkItemsEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, int * work_item_ids_array, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetWorkItemAttributeSizeEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PDG_WorkItemId work_item_id, const char * attribute_name, int * length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetWorkItemIntAttributeEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PDG_WorkItemId work_item_id, const char * attribute_name, int * data_array, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetWorkItemFloatAttributeEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PDG_WorkItemId work_item_id, const char * attribute_name, float * data_array, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetWorkItemStringAttributeEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PDG_WorkItemId work_item_id, const char * attribute_name, HAPI_StringHandle * data_array, int length)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::GetWorkItemOutputFilesEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_PDG_WorkItemId work_item_id, HAPI_PDG_WorkItemOutputFile * resultinfo_array, int resultinfo_count)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::DirtyPDGNodeEmptyStub(const HAPI_Session * session, HAPI_NodeId node_id, HAPI_Bool clean_results)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::PausePDGCookEmptyStub(const HAPI_Session * session, HAPI_PDG_GraphContextId graph_context_id)
{
    return HAPI_RESULT_FAILURE;
}
HAPI_Result
HoudiniApi::CancelPDGCookEmptyStub(const HAPI_Session * session, HAPI_PDG_GraphContextId graph_context_id)
{
    return HAPI_RESULT_FAILURE;
}
void
HoudiniApi::SessionInfo_InitEmptyStub(HAPI_SessionInfo * in)
{
    return;
}
HAPI_SessionInfo
HoudiniApi::SessionInfo_CreateEmptyStub()
{
    return HAPI_SessionInfo();
}
void
HoudiniApi::ThriftServerOptions_InitEmptyStub(HAPI_ThriftServerOptions * in)
{
    return;
}
HAPI_ThriftServerOptions
HoudiniApi::ThriftServerOptions_CreateEmptyStub()
{
    return HAPI_ThriftServerOptions();
}
void
HoudiniApi::TimelineOptions_InitEmptyStub(HAPI_TimelineOptions * in)
{
    return;
}
HAPI_TimelineOptions
HoudiniApi::TimelineOptions_CreateEmptyStub()
{
    return HAPI_TimelineOptions();
}
void
HoudiniApi::CompositorOptions_InitEmptyStub(HAPI_CompositorOptions * in)
{
    return;
}
HAPI_CompositorOptions
HoudiniApi::CompositorOptions_CreateEmptyStub()
{
    return HAPI_CompositorOptions();
}
void
HoudiniApi::AssetInfo_InitEmptyStub(HAPI_AssetInfo * in)
{
    return;
}
HAPI_AssetInfo
HoudiniApi::AssetInfo_CreateEmptyStub()
{
    return HAPI_AssetInfo();
}
void
HoudiniApi::CookOptions_InitEmptyStub(HAPI_CookOptions * in)
{
    return;
}
HAPI_CookOptions
HoudiniApi::CookOptions_CreateEmptyStub()
{
    return HAPI_CookOptions();
}
HAPI_Bool
HoudiniApi::CookOptions_AreEqualEmptyStub(const HAPI_CookOptions * left, const HAPI_CookOptions * right)
{
    return HAPI_Bool();
}
void
HoudiniApi::NodeInfo_InitEmptyStub(HAPI_NodeInfo * in)
{
    return;
}
HAPI_NodeInfo
HoudiniApi::NodeInfo_CreateEmptyStub()
{
    return HAPI_NodeInfo();
}
void
HoudiniApi::ParmInfo_InitEmptyStub(HAPI_ParmInfo * in)
{
    return;
}
HAPI_ParmInfo
HoudiniApi::ParmInfo_CreateEmptyStub()
{
    return HAPI_ParmInfo();
}
HAPI_Bool
HoudiniApi::ParmInfo_IsIntEmptyStub(const HAPI_ParmInfo * in)
{
    return HAPI_Bool();
}
HAPI_Bool
HoudiniApi::ParmInfo_IsFloatEmptyStub(const HAPI_ParmInfo * in)
{
    return HAPI_Bool();
}
HAPI_Bool
HoudiniApi::ParmInfo_IsStringEmptyStub(const HAPI_ParmInfo * in)
{
    return HAPI_Bool();
}
HAPI_Bool
HoudiniApi::ParmInfo_IsPathEmptyStub(const HAPI_ParmInfo * in)
{
    return HAPI_Bool();
}
HAPI_Bool
HoudiniApi::ParmInfo_IsNodeEmptyStub(const HAPI_ParmInfo * in)
{
    return HAPI_Bool();
}
HAPI_Bool
HoudiniApi::ParmInfo_IsNonValueEmptyStub(const HAPI_ParmInfo * in)
{
    return HAPI_Bool();
}
int
HoudiniApi::ParmInfo_GetIntValueCountEmptyStub(const HAPI_ParmInfo * in)
{
    return -1;
}
int
HoudiniApi::ParmInfo_GetFloatValueCountEmptyStub(const HAPI_ParmInfo * in)
{
    return -1;
}
int
HoudiniApi::ParmInfo_GetStringValueCountEmptyStub(const HAPI_ParmInfo* in)
{
    return -1;
}
void
HoudiniApi::ParmChoiceInfo_InitEmptyStub(HAPI_ParmChoiceInfo * in)
{
    return;
}
HAPI_ParmChoiceInfo
HoudiniApi::ParmChoiceInfo_CreateEmptyStub()
{
    return HAPI_ParmChoiceInfo();
}
void
HoudiniApi::HandleInfo_InitEmptyStub(HAPI_HandleInfo * in)
{
    return;
}
HAPI_HandleInfo
HoudiniApi::HandleInfo_CreateEmptyStub()
{
    return HAPI_HandleInfo();
}
void
HoudiniApi::HandleBindingInfo_InitEmptyStub(HAPI_HandleBindingInfo * in)
{
    return;
}
HAPI_HandleBindingInfo
HoudiniApi::HandleBindingInfo_CreateEmptyStub()
{
    return HAPI_HandleBindingInfo();
}
void
HoudiniApi::ObjectInfo_InitEmptyStub(HAPI_ObjectInfo * in)
{
    return;
}
HAPI_ObjectInfo
HoudiniApi::ObjectInfo_CreateEmptyStub()
{
    return HAPI_ObjectInfo();
}
void
HoudiniApi::GeoInfo_InitEmptyStub(HAPI_GeoInfo * in)
{
    return;
}
HAPI_GeoInfo
HoudiniApi::GeoInfo_CreateEmptyStub()
{
    return HAPI_GeoInfo();
}
int
HoudiniApi::GeoInfo_GetGroupCountByTypeEmptyStub(HAPI_GeoInfo * in, HAPI_GroupType type)
{
    return -1;
}
void
HoudiniApi::PartInfo_InitEmptyStub(HAPI_PartInfo * in)
{
    return;
}
HAPI_PartInfo
HoudiniApi::PartInfo_CreateEmptyStub()
{
    return HAPI_PartInfo();
}
int
HoudiniApi::PartInfo_GetElementCountByAttributeOwnerEmptyStub(HAPI_PartInfo * in, HAPI_AttributeOwner owner)
{
    return -1;
}
int
HoudiniApi::PartInfo_GetElementCountByGroupTypeEmptyStub(HAPI_PartInfo * in, HAPI_GroupType type)
{
    return -1;
}
int
HoudiniApi::PartInfo_GetAttributeCountByOwnerEmptyStub(HAPI_PartInfo * in, HAPI_AttributeOwner owner)
{
    return -1;
}
void
HoudiniApi::AttributeInfo_InitEmptyStub(HAPI_AttributeInfo * in)
{
    return;
}
HAPI_AttributeInfo
HoudiniApi::AttributeInfo_CreateEmptyStub()
{
    return HAPI_AttributeInfo();
}
void
HoudiniApi::MaterialInfo_InitEmptyStub(HAPI_MaterialInfo * in)
{
    return;
}
HAPI_MaterialInfo
HoudiniApi::MaterialInfo_CreateEmptyStub()
{
    return HAPI_MaterialInfo();
}
void
HoudiniApi::ImageFileFormat_InitEmptyStub(HAPI_ImageFileFormat *in)
{
    return;
}
HAPI_ImageFileFormat
HoudiniApi::ImageFileFormat_CreateEmptyStub()
{
    return HAPI_ImageFileFormat();
}
void
HoudiniApi::ImageInfo_InitEmptyStub(HAPI_ImageInfo * in)
{
    return;
}
HAPI_ImageInfo
HoudiniApi::ImageInfo_CreateEmptyStub()
{
    return HAPI_ImageInfo();
}
void
HoudiniApi::Keyframe_InitEmptyStub(HAPI_Keyframe * in)
{
    return;
}
HAPI_Keyframe
HoudiniApi::Keyframe_CreateEmptyStub()
{
    return HAPI_Keyframe();
}
void
HoudiniApi::VolumeInfo_InitEmptyStub(HAPI_VolumeInfo * in)
{
    return;
}
HAPI_VolumeInfo
HoudiniApi::VolumeInfo_CreateEmptyStub()
{
    return HAPI_VolumeInfo();
}
void
HoudiniApi::VolumeTileInfo_InitEmptyStub(HAPI_VolumeTileInfo * in)
{
    return;
}
HAPI_VolumeTileInfo
HoudiniApi::VolumeTileInfo_CreateEmptyStub()
{
    return HAPI_VolumeTileInfo();
}
void
HoudiniApi::CurveInfo_InitEmptyStub(HAPI_CurveInfo * in)
{
    return;
}
HAPI_CurveInfo
HoudiniApi::CurveInfo_CreateEmptyStub()
{
    return HAPI_CurveInfo();
}
void
HoudiniApi::InputCurveInfo_InitEmptyStub(HAPI_InputCurveInfo * in)
{
    return;
}
HAPI_InputCurveInfo
HoudiniApi::InputCurveInfo_CreateEmptyStub()
{
    return HAPI_InputCurveInfo();
}
void
HoudiniApi::Transform_InitEmptyStub(HAPI_Transform * in)
{
    return;
}
HAPI_Transform
HoudiniApi::Transform_CreateEmptyStub()
{
    return HAPI_Transform();
}
void
HoudiniApi::TransformEuler_InitEmptyStub(HAPI_TransformEuler * in)
{
    return;
}
HAPI_TransformEuler
HoudiniApi::TransformEuler_CreateEmptyStub()
{
    return HAPI_TransformEuler();
}
void
HoudiniApi::Viewport_InitEmptyStub(HAPI_Viewport * in)
{
    return;
}
HAPI_Viewport
HoudiniApi::Viewport_CreateEmptyStub()
{
    return HAPI_Viewport();
}
void
HoudiniApi::SessionSyncInfo_InitEmptyStub(HAPI_SessionSyncInfo * in)
{
    return;
}
HAPI_SessionSyncInfo
HoudiniApi::SessionSyncInfo_CreateEmptyStub()
{
    return HAPI_SessionSyncInfo();
}
