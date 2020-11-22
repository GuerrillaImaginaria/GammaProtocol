certoraRun.py specs/ControllerHarness.sol:ControllerHarness specs/MarginPoolHarness.sol:MarginPoolHarness specs/OtokenHarnessA.sol specs/OtokenHarnessB.sol specs/DummyERC20A.sol specs/DummyERC20B.sol specs/DummyERC20C.sol --link  ControllerHarness:pool=MarginPoolHarness ControllerHarness:anOtokenA=OtokenHarnessA ControllerHarness:anOtokenB=OtokenHarnessB ControllerHarness:dummyERC20C=DummyERC20C OtokenHarnessA:underlyingAsset=DummyERC20A OtokenHarnessA:strikeAsset=DummyERC20B OtokenHarnessA:collateralAsset=DummyERC20C OtokenHarnessB:underlyingAsset=DummyERC20A OtokenHarnessB:strikeAsset=DummyERC20B OtokenHarnessB:collateralAsset=DummyERC20C  --solc solc6.10 --verify ControllerHarness:specs/NoBankruptcy1.spec  --settings  -assumeUnwindCond,-b=3,-enableStorageVariableUnpacking=false,-deleteSMTFile=true,-ignoreViewFunctions,-useNonLinearArithmetic,-rule=tying_it_all_together1,-s=z3   --cache NoBankruptcy1 --path specs/,contracts/ --staging
