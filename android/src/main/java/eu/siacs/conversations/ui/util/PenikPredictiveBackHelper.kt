package eu.siacs.conversations.ui.util

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.graphics.Outline
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewOutlineProvider
import android.view.animation.PathInterpolator
import androidx.activity.BackEventCompat
import androidx.activity.OnBackPressedCallback
import androidx.fragment.app.Fragment
import eu.siacs.conversations.ui.XmppFragment
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Telegram-style Predictive Back and Edge-Swipe gesture handler for chat screens.
 * Provides interactive rounded card scaling, horizontal translation, and live preview
 * of the underlying chats list on back gesture.
 */
class PenikPredictiveBackHelper(
    private val fragment: Fragment,
    private val targetView: View,
    private val onCommitBack: Runnable
) {
    // Telegram EASE_OUT_QUINT interpolator
    private val interpolator = PathInterpolator(0.23f, 1f, 0.32f, 1f)
    private var isPredicting = false
    private var isEdgeSwiping = false
    private var currentRadius = 0f
    private val density = targetView.resources.displayMetrics.density
    private val maxRadiusPx = 22f * density
    private val screenWidth: Float
        get() = max(1f, targetView.resources.displayMetrics.widthPixels.toFloat())

    private var downX = 0f
    private var downY = 0f
    private var velocityTracker: VelocityTracker? = null
    private val touchSlop = ViewConfiguration.get(targetView.context).scaledTouchSlop
    private val edgeSwipeThresholdPx = 28f * density

    init {
        targetView.outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) {
                if (currentRadius > 0.5f) {
                    outline.setRoundRect(0, 0, view.width, view.height, currentRadius)
                } else {
                    outline.setRect(0, 0, view.width, view.height)
                }
            }
        }
        setupEdgeTouchListener()
    }

    /**
     * Predictive back callback registered with OnBackPressedDispatcher (Android 14+ / gesture nav).
     */
    val callback: OnBackPressedCallback = object : OnBackPressedCallback(true) {
        override fun handleOnBackStarted(backEvent: BackEventCompat) {
            isPredicting = true
            targetView.clipToOutline = true
            targetView.elevation = 28f * density
            ensureUnderlyingFragmentVisible()
        }

        override fun handleOnBackProgressed(backEvent: BackEventCompat) {
            if (!isPredicting) return
            applyProgress(backEvent.progress, backEvent.swipeEdge == BackEventCompat.EDGE_RIGHT)
        }

        override fun handleOnBackPressed() {
            if (isPredicting) {
                isPredicting = false
                animateDismiss()
            } else {
                isEnabled = false
                onCommitBack.run()
            }
        }

        override fun handleOnBackCancelled() {
            if (!isPredicting) return
            isPredicting = false
            animateCancel()
        }
    }

    private fun applyProgress(progress: Float, fromRight: Boolean) {
        val clamped = progress.coerceIn(0f, 1f)
        val interpolated = interpolator.getInterpolation(clamped)

        // Scale: 1.0 -> 0.91
        val scale = 1.0f - (interpolated * 0.09f)
        targetView.scaleX = scale
        targetView.scaleY = scale

        // Shift along the gesture
        val maxShift = screenWidth * 0.22f
        val shift = if (fromRight) {
            -interpolated * maxShift * 0.5f
        } else {
            interpolated * maxShift
        }
        targetView.translationX = shift

        // Rounded corners
        currentRadius = interpolated * maxRadiusPx
        targetView.invalidateOutline()

        // Parallax and dimming for underlying screen
        applyUnderlyingParallax(interpolated)
    }

    private fun animateDismiss() {
        val exitTarget = screenWidth + 30f * density
        targetView.animate()
            .translationX(exitTarget)
            .scaleX(0.92f)
            .scaleY(0.92f)
            .alpha(0.85f)
            .setDuration(220)
            .setInterpolator(interpolator)
            .setListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    XmppFragment.skipNextFragmentAnimations(2)
                    try {
                        callback.isEnabled = false
                        onCommitBack.run()
                    } finally {
                        targetView.post {
                            XmppFragment.skipNextFragmentAnimations(0)
                        }
                    }
                }
            })
            .start()

        val fm = fragment.parentFragmentManager
        for (f in fm.fragments) {
            if (f !== fragment && f.view != null) {
                f.view?.animate()
                    ?.translationX(0f)
                    ?.alpha(1.0f)
                    ?.setDuration(220)
                    ?.setInterpolator(interpolator)
                    ?.start()
            }
        }
    }

    private fun animateCancel() {
        targetView.animate()
            .scaleX(1.0f)
            .scaleY(1.0f)
            .translationX(0f)
            .translationY(0f)
            .alpha(1.0f)
            .setDuration(220)
            .setInterpolator(interpolator)
            .setListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    reset()
                }
            })
            .start()

        val fm = fragment.parentFragmentManager
        for (f in fm.fragments) {
            if (f !== fragment && f.view != null) {
                f.view?.animate()
                    ?.translationX(0f)
                    ?.alpha(1.0f)
                    ?.setDuration(220)
                    ?.setInterpolator(interpolator)
                    ?.start()
            }
        }
    }

    private fun reset() {
        targetView.scaleX = 1.0f
        targetView.scaleY = 1.0f
        targetView.translationX = 0f
        targetView.translationY = 0f
        targetView.alpha = 1.0f
        targetView.elevation = 0f
        currentRadius = 0f
        targetView.clipToOutline = false
        targetView.invalidateOutline()
        resetUnderlyingParallax()
    }

    private fun ensureUnderlyingFragmentVisible() {
        val fm = fragment.parentFragmentManager
        for (f in fm.fragments) {
            if (f !== fragment && f.view != null) {
                f.view?.visibility = View.VISIBLE
            }
        }
    }

    private fun applyUnderlyingParallax(progress: Float) {
        val fm = fragment.parentFragmentManager
        val parallaxOffset = -screenWidth * 0.12f * (1.0f - progress)
        for (f in fm.fragments) {
            if (f !== fragment && f.view != null) {
                f.view?.translationX = parallaxOffset
                f.view?.alpha = 0.85f + (progress * 0.15f)
            }
        }
    }

    private fun resetUnderlyingParallax() {
        val fm = fragment.parentFragmentManager
        for (f in fm.fragments) {
            if (f !== fragment && f.view != null) {
                f.view?.translationX = 0f
                f.view?.alpha = 1.0f
            }
        }
    }

    /**
     * Intercepts left-edge drag gestures to provide interactive swipe-back on any Android version.
     */
    private fun setupEdgeTouchListener() {
        // Hook touch dispatch through a simple touch listener on target view
        val existingTouchListener = targetView.setOnTouchListener { _, event ->
            handleTouch(event)
        }
    }

    fun handleTouch(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                if (event.rawX <= edgeSwipeThresholdPx) {
                    isEdgeSwiping = true
                    downX = event.rawX
                    downY = event.rawY
                    targetView.clipToOutline = true
                    targetView.elevation = 28f * density
                    ensureUnderlyingFragmentVisible()
                    velocityTracker = VelocityTracker.obtain()
                    velocityTracker?.addMovement(event)
                    return true
                }
            }
            MotionEvent.ACTION_MOVE -> {
                if (isEdgeSwiping) {
                    velocityTracker?.addMovement(event)
                    val dx = event.rawX - downX
                    val dy = abs(event.rawY - downY)
                    if (dx > 0 && dx > dy) {
                        val progress = (dx / (screenWidth * 0.85f)).coerceIn(0f, 1f)
                        applyProgress(progress, false)
                        return true
                    }
                }
            }
            MotionEvent.ACTION_UP -> {
                if (isEdgeSwiping) {
                    velocityTracker?.addMovement(event)
                    velocityTracker?.computeCurrentVelocity(1000)
                    val xVelocity = velocityTracker?.xVelocity ?: 0f
                    val dx = event.rawX - downX
                    velocityTracker?.recycle()
                    velocityTracker = null
                    isEdgeSwiping = false

                    if (dx > screenWidth * 0.35f || xVelocity > 1000f) {
                        animateDismiss()
                    } else {
                        animateCancel()
                    }
                    return true
                }
            }
            MotionEvent.ACTION_CANCEL -> {
                if (isEdgeSwiping) {
                    velocityTracker?.recycle()
                    velocityTracker = null
                    isEdgeSwiping = false
                    animateCancel()
                    return true
                }
            }
        }
        return false
    }
}
