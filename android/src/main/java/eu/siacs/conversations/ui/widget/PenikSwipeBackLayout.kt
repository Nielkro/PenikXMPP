package eu.siacs.conversations.ui.widget

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.animation.PathInterpolator
import android.widget.FrameLayout
import androidx.fragment.app.Fragment
import eu.siacs.conversations.ui.ConversationsActivity
import eu.siacs.conversations.ui.XmppFragment
import kotlin.math.abs
import kotlin.math.max

/**
 * Telegram-style Follow-the-finger Swipe Back Layout for chat screens.
 * Intercepts left-edge drags in dispatchTouchEvent to overcome child touch interception,
 * tracks finger position 1:1, draws an edge shadow, moves the underlying screen with smooth parallax,
 * and dismisses without duplicate animations or flicker.
 */
class PenikSwipeBackLayout @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : FrameLayout(context, attrs, defStyleAttr) {

    private val density = resources.displayMetrics.density
    private val shadowWidthPx = (22f * density).toInt()
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private val interpolator = PathInterpolator(0.23f, 1f, 0.32f, 1f)

    // Telegram allows swiping right from almost anywhere across the screen
    private val maxSwipeStartX: Float
        get() {
            val totalWidth = if (width > 0) width.toFloat() else resources.displayMetrics.widthPixels.toFloat()
            return totalWidth * 0.88f
        }

    private val shadowDrawable = GradientDrawable(
        GradientDrawable.Orientation.RIGHT_LEFT,
        intArrayOf(Color.argb(85, 0, 0, 0), Color.TRANSPARENT)
    )

    private var downX = 0f
    private var downY = 0f
    private var isEdgeTouch = false
    private var isDragging = false
    private var isAnimating = false
    private var velocityTracker: VelocityTracker? = null

    var fragment: Fragment? = null
    var onSwipeStarted: Runnable? = null
    var onDismissed: Runnable? = null

    private val currentContentView: View?
        get() = if (childCount > 0) getChildAt(0) else null

    private val isTablet: Boolean
        get() {
            val activity = fragment?.activity ?: return false
            return ConversationsActivity.isTabletView(activity)
        }

    init {
        setWillNotDraw(false)
        clipChildren = false
    }

    override fun requestDisallowInterceptTouchEvent(disallowIntercept: Boolean) {
        if (isEdgeTouch) {
            // Do NOT allow children (Compose, RecyclerView) to block our edge swipe
            return
        }
        super.requestDisallowInterceptTouchEvent(disallowIntercept)
    }

    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        if (!isEnabled || isAnimating || isTablet) {
            return super.dispatchTouchEvent(ev)
        }

        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = ev.rawX
                downY = ev.rawY
                isDragging = false
                isEdgeTouch = ev.x <= maxSwipeStartX
                if (isEdgeTouch) {
                    velocityTracker?.recycle()
                    velocityTracker = VelocityTracker.obtain()
                    velocityTracker?.addMovement(ev)
                }
            }
            MotionEvent.ACTION_MOVE -> {
                if (isEdgeTouch && !isDragging) {
                    val dx = ev.rawX - downX
                    val dy = abs(ev.rawY - downY)
                    if (dx > touchSlop && dx > dy * 1.1f) {
                        isDragging = true
                        parent?.requestDisallowInterceptTouchEvent(true)
                        ensureUnderlyingFragmentVisible()
                        onSwipeStarted?.run()

                        // Cancel child gestures by dispatching ACTION_CANCEL to child views
                        val cancelEvent = MotionEvent.obtain(ev).apply {
                            action = MotionEvent.ACTION_CANCEL
                        }
                        super.dispatchTouchEvent(cancelEvent)
                        cancelEvent.recycle()
                    } else if (dy > touchSlop && dy > dx) {
                        isEdgeTouch = false
                    }
                }

                if (isDragging) {
                    velocityTracker?.addMovement(ev)
                    val dx = max(0f, ev.rawX - downX)
                    applySwipeOffset(dx)
                    return true
                }
            }
            MotionEvent.ACTION_UP -> {
                if (isDragging) {
                    velocityTracker?.addMovement(ev)
                    velocityTracker?.computeCurrentVelocity(1000)
                    val vx = velocityTracker?.xVelocity ?: 0f
                    val currentShift = currentContentView?.translationX ?: 0f
                    val totalWidth = max(1f, width.toFloat())
                    val shouldDismiss = (currentShift > totalWidth * 0.35f || vx > 1000f) && vx >= -200f

                    if (shouldDismiss) {
                        animateDismiss(vx)
                    } else {
                        animateCancel()
                    }
                    isDragging = false
                    isEdgeTouch = false
                    velocityTracker?.recycle()
                    velocityTracker = null
                    return true
                }
                isEdgeTouch = false
                isDragging = false
                velocityTracker?.recycle()
                velocityTracker = null
            }
            MotionEvent.ACTION_CANCEL -> {
                if (isDragging) {
                    animateCancel()
                    isDragging = false
                    isEdgeTouch = false
                    velocityTracker?.recycle()
                    velocityTracker = null
                    return true
                }
                isEdgeTouch = false
                isDragging = false
                velocityTracker?.recycle()
                velocityTracker = null
            }
        }

        return super.dispatchTouchEvent(ev)
    }

    private fun applySwipeOffset(dx: Float) {
        val child = currentContentView ?: return
        val clampedDx = max(0f, dx)
        child.translationX = clampedDx

        val totalWidth = max(1f, width.toFloat())
        val progress = (clampedDx / totalWidth).coerceIn(0f, 1f)
        applyUnderlyingParallax(progress)
        invalidate()
    }

    override fun dispatchDraw(canvas: Canvas) {
        super.dispatchDraw(canvas)
        val child = currentContentView
        if (child != null && child.translationX > 0f) {
            val left = child.translationX.toInt()
            shadowDrawable.setBounds(left - shadowWidthPx, child.top, left, child.bottom)
            val progress = (child.translationX / max(1f, width.toFloat())).coerceIn(0f, 1f)
            val alpha = ((1f - progress * 0.4f) * 255).toInt().coerceIn(0, 255)
            shadowDrawable.alpha = alpha
            shadowDrawable.draw(canvas)
        }
    }

    private fun animateDismiss(velocity: Float) {
        val child = currentContentView ?: return
        isAnimating = true
        val startX = child.translationX
        val endX = width.toFloat() + shadowWidthPx + 10f * density

        val remainingDistance = max(1f, endX - startX)
        val calculatedDuration = if (velocity > 1000f) {
            ((remainingDistance / velocity) * 1000).toLong().coerceIn(120, 220)
        } else {
            220L
        }

        val animator = ValueAnimator.ofFloat(startX, endX).apply {
            duration = calculatedDuration
            interpolator = this@PenikSwipeBackLayout.interpolator
            addUpdateListener { va ->
                val currentX = va.animatedValue as Float
                child.translationX = currentX
                val progress = (currentX / max(1f, width.toFloat())).coerceIn(0f, 1f)
                applyUnderlyingParallax(progress)
                invalidate()
            }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    isAnimating = false
                    XmppFragment.skipNextFragmentAnimations(2)
                    try {
                        onDismissed?.run()
                    } finally {
                        post {
                            XmppFragment.skipNextFragmentAnimations(0)
                        }
                    }
                }
            })
        }
        animator.start()
    }

    private fun animateCancel() {
        val child = currentContentView ?: return
        isAnimating = true
        val startX = child.translationX

        val animator = ValueAnimator.ofFloat(startX, 0f).apply {
            duration = 200L
            interpolator = this@PenikSwipeBackLayout.interpolator
            addUpdateListener { va ->
                val currentX = va.animatedValue as Float
                child.translationX = currentX
                val progress = (currentX / max(1f, width.toFloat())).coerceIn(0f, 1f)
                applyUnderlyingParallax(progress)
                invalidate()
            }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    isAnimating = false
                    child.translationX = 0f
                    resetUnderlyingParallax()
                    invalidate()
                }
            })
        }
        animator.start()
    }

    private fun ensureUnderlyingFragmentVisible() {
        val host = fragment ?: return
        val fm = host.parentFragmentManager
        for (f in fm.fragments) {
            if (f !== host && f.view != null) {
                f.view?.visibility = View.VISIBLE
            }
        }
    }

    private fun applyUnderlyingParallax(progress: Float) {
        val host = fragment ?: return
        val fm = host.parentFragmentManager
        val totalWidth = max(1f, width.toFloat())
        val parallaxOffset = -totalWidth * 0.25f * (1.0f - progress)
        for (f in fm.fragments) {
            if (f !== host && f.view != null) {
                f.view?.translationX = parallaxOffset
                f.view?.alpha = 0.85f + (progress * 0.15f)
            }
        }
    }

    private fun resetUnderlyingParallax() {
        val host = fragment ?: return
        val fm = host.parentFragmentManager
        for (f in fm.fragments) {
            if (f !== host && f.view != null) {
                f.view?.translationX = 0f
                f.view?.alpha = 1.0f
            }
        }
    }
}
