package eu.siacs.conversations.ui.compose

import android.graphics.BitmapFactory
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.colorResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import eu.siacs.conversations.R

enum class PenikAuthMode {
    WELCOME,
    REGISTER,
    LOGIN
}

data class PenikAuthState(
    val isLoading: Boolean = false,
    val error: String? = null,
    val initialMode: PenikAuthMode = PenikAuthMode.WELCOME,
    val initialNickname: String = "",
    val inviteDomain: String? = null,
    val preAuthToken: String? = null
)

interface PenikAuthListener {
    fun onRegister(nickname: String, password: String, displayName: String, avatarUri: Uri?)
    fun onLogin(usernameOrJid: String, password: String)
    fun onImportBackup()
}

@Composable
fun PenikAuthScreen(
    state: PenikAuthState,
    listener: PenikAuthListener
) {
    val context = LocalContext.current
    var mode by remember(state.initialMode) { mutableStateOf(state.initialMode) }
    var step by remember(state.initialMode, state.initialNickname) {
        mutableIntStateOf(if (state.initialNickname.isNotBlank() && state.initialMode == PenikAuthMode.REGISTER) 1 else 0)
    }

    var nickname by remember(state.initialNickname) { mutableStateOf(state.initialNickname) }
    var password by remember { mutableStateOf("") }
    var displayName by remember { mutableStateOf("") }
    var avatarUri by remember { mutableStateOf<Uri?>(null) }
    var localError by remember { mutableStateOf<String?>(null) }

    val bg = colorResource(R.color.penik_background)
    val accent = colorResource(R.color.penik_accent)
    val border = colorResource(R.color.penik_border)
    val textPrimary = colorResource(R.color.penik_text_primary)
    val textMuted = colorResource(R.color.penik_text_muted)
    val inputBg = colorResource(R.color.penik_input_bg)
    val danger = colorResource(R.color.penik_danger)

    val imageLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.GetContent()
    ) { uri: Uri? ->
        if (uri != null) {
            avatarUri = uri
        }
    }

    val goBack = {
        localError = null
        if (step > 0) {
            step--
        } else {
            mode = PenikAuthMode.WELCOME
        }
    }

    BackHandler(enabled = mode != PenikAuthMode.WELCOME) {
        goBack()
    }

    val displayError = localError ?: state.error

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(bg)
            .padding(24.dp)
    ) {
        // Back Button & Steps Progress Bar (when inside wizard)
        if (mode != PenikAuthMode.WELCOME) {
            IconButton(
                onClick = { goBack() },
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .padding(top = 8.dp)
            ) {
                Text(
                    text = "←",
                    color = textPrimary,
                    fontSize = 24.sp,
                    fontWeight = FontWeight.Bold
                )
            }

            val maxSteps = if (mode == PenikAuthMode.REGISTER) 3 else 2
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .align(Alignment.TopCenter)
                    .padding(horizontal = 48.dp, vertical = 24.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                for (i in 0 until maxSteps) {
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .height(4.dp)
                            .clip(RoundedCornerShape(2.dp))
                            .background(
                                if (i <= step) accent else Color.White.copy(alpha = 0.1f)
                            )
                    )
                }
            }
        }

        // Main Contents
        Column(
            modifier = Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            when (mode) {
                PenikAuthMode.WELCOME -> {
                    Text(
                        text = "Penik",
                        color = accent,
                        fontSize = 38.sp,
                        fontWeight = FontWeight.Bold
                    )
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = "Быстрый и удобный мессенджер",
                        color = textMuted,
                        fontSize = 15.sp
                    )
                    Spacer(modifier = Modifier.height(52.dp))
                    Button(
                        onClick = {
                            localError = null
                            step = 0
                            mode = PenikAuthMode.REGISTER
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(52.dp),
                        shape = RoundedCornerShape(14.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = accent)
                    ) {
                        Text("Регистрация", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                    }
                    Spacer(modifier = Modifier.height(14.dp))
                    Button(
                        onClick = {
                            localError = null
                            step = 0
                            mode = PenikAuthMode.LOGIN
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(52.dp)
                            .border(1.dp, border, RoundedCornerShape(14.dp)),
                        shape = RoundedCornerShape(14.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent)
                    ) {
                        Text("Войти", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = textPrimary)
                    }
                    Spacer(modifier = Modifier.height(28.dp))
                    TextButton(onClick = { listener.onImportBackup() }) {
                        Text(
                            text = "Восстановить из резервной копии",
                            color = textMuted,
                            fontSize = 13.sp
                        )
                    }
                }

                PenikAuthMode.REGISTER -> {
                    when (step) {
                        0 -> { // Nickname
                            Text(
                                text = "Выберите никнейм",
                                fontSize = 22.sp,
                                fontWeight = FontWeight.Bold,
                                color = textPrimary
                            )
                            Spacer(modifier = Modifier.height(8.dp))
                            if (!state.inviteDomain.isNullOrBlank()) {
                                Text(
                                    text = "Приглашение на ${state.inviteDomain}",
                                    fontSize = 13.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    color = accent
                                )
                                Spacer(modifier = Modifier.height(4.dp))
                            }
                            Text(
                                text = "Уникальное имя для поиска в сети",
                                fontSize = 13.sp,
                                color = textMuted
                            )
                            Spacer(modifier = Modifier.height(32.dp))
                            OutlinedTextField(
                                value = nickname,
                                onValueChange = {
                                    nickname = it.trim().lowercase()
                                    localError = null
                                },
                                label = { Text("Никнейм") },
                                placeholder = { Text("username") },
                                singleLine = true,
                                modifier = Modifier.fillMaxWidth(),
                                shape = RoundedCornerShape(14.dp),
                                colors = OutlinedTextFieldDefaults.colors(
                                    focusedContainerColor = inputBg,
                                    unfocusedContainerColor = inputBg,
                                    focusedBorderColor = accent,
                                    unfocusedBorderColor = border,
                                    focusedTextColor = textPrimary,
                                    unfocusedTextColor = textPrimary,
                                    focusedLabelColor = accent,
                                    unfocusedLabelColor = textMuted
                                )
                            )
                            RenderAuthError(displayError, danger)
                            Spacer(modifier = Modifier.height(24.dp))
                            PrimaryAuthButton(
                                text = "Продолжить",
                                isLoading = false,
                                accentColor = accent,
                                onClick = {
                                    val nick = nickname.trim().lowercase()
                                    if (nick.length < 3) {
                                        localError = "Никнейм должен содержать минимум 3 символа"
                                    } else if (!nick.matches(Regex("^[a-z0-9_.-]+$"))) {
                                        localError = "Допустимы только латинские буквы, цифры, точки и дефисы"
                                    } else {
                                        localError = null
                                        step = 1
                                    }
                                }
                            )
                        }

                        1 -> { // Password
                            Text(
                                text = "Создайте пароль",
                                fontSize = 22.sp,
                                fontWeight = FontWeight.Bold,
                                color = textPrimary
                            )
                            Spacer(modifier = Modifier.height(8.dp))
                            Text(
                                text = "Используется для входа в ваш аккаунт",
                                fontSize = 13.sp,
                                color = textMuted
                            )
                            Spacer(modifier = Modifier.height(32.dp))
                            OutlinedTextField(
                                value = password,
                                onValueChange = {
                                    password = it
                                    localError = null
                                },
                                label = { Text("Пароль") },
                                singleLine = true,
                                visualTransformation = PasswordVisualTransformation(),
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                                modifier = Modifier.fillMaxWidth(),
                                shape = RoundedCornerShape(14.dp),
                                colors = OutlinedTextFieldDefaults.colors(
                                    focusedContainerColor = inputBg,
                                    unfocusedContainerColor = inputBg,
                                    focusedBorderColor = accent,
                                    unfocusedBorderColor = border,
                                    focusedTextColor = textPrimary,
                                    unfocusedTextColor = textPrimary,
                                    focusedLabelColor = accent,
                                    unfocusedLabelColor = textMuted
                                )
                            )
                            RenderAuthError(displayError, danger)
                            Spacer(modifier = Modifier.height(24.dp))
                            PrimaryAuthButton(
                                text = "Продолжить",
                                isLoading = false,
                                accentColor = accent,
                                onClick = {
                                    if (password.length < 4) {
                                        localError = "Пароль должен содержать минимум 4 символа"
                                    } else {
                                        localError = null
                                        if (displayName.isBlank()) {
                                            displayName = nickname
                                        }
                                        step = 2
                                    }
                                }
                            )
                        }

                        2 -> { // Avatar & Display Name
                            Text(
                                text = "Ваша аватарка и имя",
                                fontSize = 22.sp,
                                fontWeight = FontWeight.Bold,
                                color = textPrimary
                            )
                            Spacer(modifier = Modifier.height(8.dp))
                            Text(
                                text = "Загрузите фото и укажите отображаемое имя",
                                fontSize = 13.sp,
                                color = textMuted
                            )
                            Spacer(modifier = Modifier.height(24.dp))

                            Box(
                                modifier = Modifier
                                    .size(96.dp)
                                    .clip(CircleShape)
                                    .background(Color.White.copy(alpha = 0.05f))
                                    .border(1.dp, border, CircleShape)
                                    .clickable { imageLauncher.launch("image/*") },
                                contentAlignment = Alignment.Center
                            ) {
                                if (avatarUri != null) {
                                    val bitmap = remember(avatarUri) {
                                        try {
                                            context.contentResolver.openInputStream(avatarUri!!)?.use {
                                                BitmapFactory.decodeStream(it)
                                            }
                                        } catch (e: Exception) {
                                            null
                                        }
                                    }
                                    if (bitmap != null) {
                                        Image(
                                            bitmap = bitmap.asImageBitmap(),
                                            contentDescription = "Avatar Preview",
                                            modifier = Modifier.fillMaxSize()
                                        )
                                    } else {
                                        Text("+", fontSize = 32.sp, color = textMuted)
                                    }
                                } else {
                                    Text("+", fontSize = 32.sp, color = textMuted)
                                }
                            }

                            Spacer(modifier = Modifier.height(24.dp))
                            OutlinedTextField(
                                value = displayName,
                                onValueChange = {
                                    displayName = it
                                    localError = null
                                },
                                label = { Text("Имя") },
                                placeholder = { Text("Ваше имя") },
                                singleLine = true,
                                modifier = Modifier.fillMaxWidth(),
                                shape = RoundedCornerShape(14.dp),
                                colors = OutlinedTextFieldDefaults.colors(
                                    focusedContainerColor = inputBg,
                                    unfocusedContainerColor = inputBg,
                                    focusedBorderColor = accent,
                                    unfocusedBorderColor = border,
                                    focusedTextColor = textPrimary,
                                    unfocusedTextColor = textPrimary,
                                    focusedLabelColor = accent,
                                    unfocusedLabelColor = textMuted
                                )
                            )
                            RenderAuthError(displayError, danger)
                            Spacer(modifier = Modifier.height(24.dp))
                            PrimaryAuthButton(
                                text = "Завершить регистрацию",
                                isLoading = state.isLoading,
                                accentColor = accent,
                                onClick = {
                                    listener.onRegister(
                                        nickname = nickname.trim().lowercase(),
                                        password = password,
                                        displayName = displayName.trim(),
                                        avatarUri = avatarUri
                                    )
                                }
                            )
                        }
                    }
                }

                PenikAuthMode.LOGIN -> {
                    when (step) {
                        0 -> { // Login Nickname / JID
                            Text(
                                text = "Введите никнейм",
                                fontSize = 22.sp,
                                fontWeight = FontWeight.Bold,
                                color = textPrimary
                            )
                            Spacer(modifier = Modifier.height(8.dp))
                            Text(
                                text = "Укажите ваш никнейм для входа",
                                fontSize = 13.sp,
                                color = textMuted
                            )
                            Spacer(modifier = Modifier.height(32.dp))
                            OutlinedTextField(
                                value = nickname,
                                onValueChange = {
                                    nickname = it.trim().lowercase()
                                    localError = null
                                },
                                label = { Text("Никнейм") },
                                placeholder = { Text("@username") },
                                singleLine = true,
                                modifier = Modifier.fillMaxWidth(),
                                shape = RoundedCornerShape(14.dp),
                                colors = OutlinedTextFieldDefaults.colors(
                                    focusedContainerColor = inputBg,
                                    unfocusedContainerColor = inputBg,
                                    focusedBorderColor = accent,
                                    unfocusedBorderColor = border,
                                    focusedTextColor = textPrimary,
                                    unfocusedTextColor = textPrimary,
                                    focusedLabelColor = accent,
                                    unfocusedLabelColor = textMuted
                                )
                            )
                            RenderAuthError(displayError, danger)
                            Spacer(modifier = Modifier.height(24.dp))
                            PrimaryAuthButton(
                                text = "Продолжить",
                                isLoading = false,
                                accentColor = accent,
                                onClick = {
                                    val nick = nickname.trim().lowercase().removePrefix("@")
                                    if (nick.isBlank()) {
                                        localError = "Введите никнейм"
                                    } else {
                                        localError = null
                                        nickname = nick
                                        step = 1
                                    }
                                }
                            )
                        }

                        1 -> { // Login Password
                            Text(
                                text = "Введите пароль",
                                fontSize = 22.sp,
                                fontWeight = FontWeight.Bold,
                                color = textPrimary
                            )
                            Spacer(modifier = Modifier.height(8.dp))
                            Text(
                                text = "Пароль от вашего аккаунта Penik",
                                fontSize = 13.sp,
                                color = textMuted
                            )
                            Spacer(modifier = Modifier.height(32.dp))
                            OutlinedTextField(
                                value = password,
                                onValueChange = {
                                    password = it
                                    localError = null
                                },
                                label = { Text("Пароль") },
                                singleLine = true,
                                visualTransformation = PasswordVisualTransformation(),
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                                modifier = Modifier.fillMaxWidth(),
                                shape = RoundedCornerShape(14.dp),
                                colors = OutlinedTextFieldDefaults.colors(
                                    focusedContainerColor = inputBg,
                                    unfocusedContainerColor = inputBg,
                                    focusedBorderColor = accent,
                                    unfocusedBorderColor = border,
                                    focusedTextColor = textPrimary,
                                    unfocusedTextColor = textPrimary,
                                    focusedLabelColor = accent,
                                    unfocusedLabelColor = textMuted
                                )
                            )
                            RenderAuthError(displayError, danger)
                            Spacer(modifier = Modifier.height(24.dp))
                            PrimaryAuthButton(
                                text = "Войти",
                                isLoading = state.isLoading,
                                accentColor = accent,
                                onClick = {
                                    if (password.isBlank()) {
                                        localError = "Введите пароль"
                                    } else {
                                        listener.onLogin(
                                            usernameOrJid = nickname.trim().lowercase().removePrefix("@"),
                                            password = password
                                        )
                                    }
                                }
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun RenderAuthError(error: String?, dangerColor: Color) {
    if (error != null) {
        Spacer(modifier = Modifier.height(12.dp))
        Text(
            text = error,
            color = dangerColor,
            fontSize = 14.sp,
            textAlign = TextAlign.Center
        )
    }
}

@Composable
private fun PrimaryAuthButton(
    text: String,
    isLoading: Boolean,
    accentColor: Color,
    onClick: () -> Unit
) {
    Button(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth()
            .height(52.dp),
        shape = RoundedCornerShape(14.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = accentColor,
            disabledContainerColor = accentColor.copy(alpha = 0.5f)
        ),
        enabled = !isLoading
    ) {
        if (isLoading) {
            CircularProgressIndicator(
                color = Color.White,
                strokeWidth = 2.dp,
                modifier = Modifier.size(24.dp)
            )
        } else {
            Text(
                text = text,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                color = Color.White
            )
        }
    }
}
