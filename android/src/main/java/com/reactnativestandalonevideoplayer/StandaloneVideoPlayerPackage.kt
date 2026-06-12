package com.reactnativestandalonevideoplayer

import android.view.View
import com.facebook.react.BaseReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider
import com.facebook.react.uimanager.ReactShadowNode
import com.facebook.react.uimanager.ViewManager

// BaseReactPackage registration (TurboReactPackage was deprecated in RN 0.77 in favor of
// BaseReactPackage — same surface, renamed parent). Module loads on the new architecture's
// TurboModule path. View manager (PlayerContainerView) remains registered through the legacy
// ViewManager interop until Fabric migration (Stage 1c).
class StandaloneVideoPlayerPackage : BaseReactPackage() {

  override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? =
    if (name == StandaloneVideoPlayer.NAME) StandaloneVideoPlayer(reactContext) else null

  override fun getReactModuleInfoProvider(): ReactModuleInfoProvider = ReactModuleInfoProvider {
    mapOf(
      StandaloneVideoPlayer.NAME to ReactModuleInfo(
        StandaloneVideoPlayer.NAME,
        StandaloneVideoPlayer::class.java.name,
        false, // canOverrideExistingModule
        false, // needsEagerInit
        false, // isCxxModule
        true   // isTurboModule
      )
    )
  }

  override fun createViewManagers(reactContext: ReactApplicationContext): MutableList<ViewManager<out View, out ReactShadowNode<*>>> =
    mutableListOf(PlayerContainerView())
}
