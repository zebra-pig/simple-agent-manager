#!/usr/bin/env python3
"""Create an isolated simulator UI-test project; never alter SAM.xcodeproj.
Usage: python3 make-project.py /absolute/scratch/Picker.xcodeproj
Requires ios/Generated from apps/native/scripts/build-ios.sh.
"""
import pathlib
import plistlib
import sys

source = pathlib.Path(__file__).resolve().parent
ios = source.parents[1]
output = pathlib.Path(sys.argv[1]).resolve()
objects = {}


def obj(isa, **values):
    key = f'{len(objects) + 1:024X}'
    objects[key] = dict(isa=isa, **values)
    return key


def ref(path, kind):
    return obj('PBXFileReference', path=str(path), sourceTree='<absolute>', lastKnownFileType=kind)


def configs(settings):
    config = obj('XCBuildConfiguration', name='Debug', buildSettings=settings)
    return obj('XCConfigurationList', buildConfigurations=[config], defaultConfigurationIsVisible=0,
               defaultConfigurationName='Debug')


common = dict(ARCHS='arm64', ONLY_ACTIVE_ARCH='YES', SWIFT_VERSION='5.0', IPHONEOS_DEPLOYMENT_TARGET='17.0', SDKROOT='iphonesimulator',
              TARGETED_DEVICE_FAMILY='1,2', CODE_SIGNING_ALLOWED='NO', GENERATE_INFOPLIST_FILE='YES',
              SWIFT_OPTIMIZATION_LEVEL='-Onone', CLANG_ENABLE_MODULES='YES',
              PRODUCT_NAME='$(TARGET_NAME)', SUPPORTED_PLATFORMS='iphonesimulator',
              LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks'])
files = sorted((ios / 'SAM').glob('*.swift'))
files = [p for p in files if p.name != 'SAMApp.swift'] + [ios / 'Generated/SamCore.swift', source / 'PickerFixture.swift']
references = [ref(p, 'sourcecode.swift') for p in files]
framework = ref(ios / 'Generated/SamCore.xcframework', 'wrapper.xcframework')
app_product = obj('PBXFileReference', path='PickerFixture.app', sourceTree='BUILT_PRODUCTS_DIR', explicitFileType='wrapper.application')
app_target = obj('PBXNativeTarget', name='PickerFixture', productName='PickerFixture', productReference=app_product,
                 productType='com.apple.product-type.application', dependencies=[], buildRules=[],
                 buildConfigurationList=configs(dict(common, PRODUCT_BUNDLE_IDENTIFIER='dev.zebrapig.pickerfixture',
                   INFOPLIST_KEY_UIFileSharingEnabled='YES', INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace='YES',
                   INFOPLIST_KEY_UILaunchScreen_Generation='YES', INFOPLIST_KEY_UIApplicationSceneManifest_Generation='YES')),
                 buildPhases=[obj('PBXSourcesBuildPhase', files=[obj('PBXBuildFile', fileRef=r) for r in references], buildActionMask=2147483647),
                              obj('PBXFrameworksBuildPhase', files=[obj('PBXBuildFile', fileRef=framework)], buildActionMask=2147483647)])
test_ref = ref(source / 'PickerUITests.swift', 'sourcecode.swift')
test_product = obj('PBXFileReference', path='PickerUITests.xctest', sourceTree='BUILT_PRODUCTS_DIR', explicitFileType='wrapper.cfbundle')
test_target = obj('PBXNativeTarget', name='PickerUITests', productName='PickerUITests', productReference=test_product,
                  productType='com.apple.product-type.bundle.ui-testing', buildRules=[],
                  dependencies=[obj('PBXTargetDependency', target=app_target)],
                  buildConfigurationList=configs(dict(common, PRODUCT_BUNDLE_IDENTIFIER='dev.zebrapig.pickerfixture.tests', TEST_TARGET_NAME='PickerFixture')),
                  buildPhases=[obj('PBXSourcesBuildPhase', files=[obj('PBXBuildFile', fileRef=test_ref)], buildActionMask=2147483647),
                               obj('PBXFrameworksBuildPhase', files=[], buildActionMask=2147483647)])
products = obj('PBXGroup', children=[app_product, test_product], name='Products', sourceTree='<group>')
root = obj('PBXProject', buildConfigurationList=configs(common), compatibilityVersion='Xcode 14.0',
           developmentRegion='en', knownRegions=['en'], projectDirPath='', projectRoot='',
           mainGroup=obj('PBXGroup', children=references + [framework, test_ref, products], sourceTree='<group>'),
           productRefGroup=products, targets=[app_target, test_target],
           attributes=dict(TargetAttributes={test_target: dict(TestTargetID=app_target)}))
output.mkdir(parents=True, exist_ok=True)
(output / 'project.pbxproj').write_bytes(plistlib.dumps(dict(archiveVersion='1', objectVersion='56', classes={}, objects=objects, rootObject=root)))
schemes = output / 'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
def buildable(target, name, product):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:{output.name}"/>'
(schemes / 'Picker.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{buildable(app_target, 'PickerFixture', 'PickerFixture.app')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{buildable(test_target, 'PickerUITests', 'PickerUITests.xctest')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug"><BuildableProductRunnable runnableDebuggingMode="0">{buildable(app_target, 'PickerFixture', 'PickerFixture.app')}</BuildableProductRunnable></LaunchAction>
</Scheme>''')
print(output)
