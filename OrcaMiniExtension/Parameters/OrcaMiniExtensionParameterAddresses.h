//
//  OrcaMiniExtensionParameterAddresses.h
//
#pragma once
#include <AudioToolbox/AUParameters.h>

typedef NS_ENUM(AUParameterAddress, OrcaMiniExtensionParameterAddress) {
    speedIndex = 0      // 0-7: frames per beat ladder 1,2,3,4,6,8,12,16 (3 = Orca's native 1/16)
};
