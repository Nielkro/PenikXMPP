package eu.siacs.conversations.ui.compose.navigation

import androidx.compose.animation.AnimatedContentTransitionScope
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import eu.siacs.conversations.ui.XmppActivity
import eu.siacs.conversations.ui.compose.PenikChatsListener
import eu.siacs.conversations.ui.compose.PenikChatsState
import eu.siacs.conversations.ui.compose.PenikMainScreen

sealed class PenikScreen(val route: String) {
    data object Main : PenikScreen("penik_main")
    data object Archive : PenikScreen("penik_archive")
    data object Calls : PenikScreen("penik_calls")
    data object Profile : PenikScreen("penik_profile")
}

@Composable
fun PenikInternalNavHost(
    activity: XmppActivity,
    state: PenikChatsState,
    listener: PenikChatsListener,
    modifier: Modifier = Modifier,
    navController: NavHostController = rememberNavController()
) {
    NavHost(
        navController = navController,
        startDestination = PenikScreen.Main.route,
        modifier = modifier,
        enterTransition = {
            fadeIn(animationSpec = tween(220)) + slideIntoContainer(
                AnimatedContentTransitionScope.SlideDirection.Start,
                tween(220)
            )
        },
        exitTransition = {
            fadeOut(animationSpec = tween(220)) + slideOutOfContainer(
                AnimatedContentTransitionScope.SlideDirection.Start,
                tween(220)
            )
        },
        popEnterTransition = {
            fadeIn(animationSpec = tween(220)) + slideIntoContainer(
                AnimatedContentTransitionScope.SlideDirection.End,
                tween(220)
            )
        },
        popExitTransition = {
            fadeOut(animationSpec = tween(220)) + slideOutOfContainer(
                AnimatedContentTransitionScope.SlideDirection.End,
                tween(220)
            )
        }
    ) {
        composable(PenikScreen.Main.route) {
            PenikMainScreen(
                state = state,
                activity = activity,
                listener = listener
            )
        }
    }
}
