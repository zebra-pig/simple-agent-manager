package org.simpleagentmanager.app

import android.app.Application
import androidx.compose.runtime.mutableStateListOf
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import org.simpleagentmanager.core.AppObserver
import org.simpleagentmanager.core.AppState
import org.simpleagentmanager.core.AuthStatus
import org.simpleagentmanager.core.ChatObserver
import org.simpleagentmanager.core.ChatState
import org.simpleagentmanager.core.ChatViewModel
import org.simpleagentmanager.core.ProjectListObserver
import org.simpleagentmanager.core.ProjectListState
import org.simpleagentmanager.core.ProjectListViewModel
import org.simpleagentmanager.core.ProjectObserver
import org.simpleagentmanager.core.ProjectState
import org.simpleagentmanager.core.ProjectViewModel

// Thin wrappers: each registers as its Rust view model's observer and exposes
// the snapshots as a StateFlow (observers may fire on a Rust worker thread;
// MutableStateFlow is thread-safe and Compose collects on the main thread).

/** One entry of the back stack. */
sealed interface Route {
    data object Projects : Route
    data object Account : Route
    data class Project(val id: String, val name: String) : Route
    data class Chat(val projectId: String, val sessionId: String) : Route
}

class SessionModel(application: Application) : AndroidViewModel(application) {
    val app = (application as SamApplication).core
    private val _state = MutableStateFlow(app.state())
    val state: StateFlow<AppState> = _state
    val stack = mutableStateListOf<Route>(Route.Projects)

    fun push(route: Route) { if (stack.last() != route) stack.add(route) }
    fun pop() { if (stack.size > 1) stack.removeAt(stack.lastIndex) }

    init {
        app.setObserver(object : AppObserver {
            override fun onStateChanged(state: AppState) { _state.value = state }
        })
        _state.value = app.state()
        if (_state.value.status == AuthStatus.SIGNED_IN) viewModelScope.launch { app.refreshViewer() }
    }

    /** Device flow: get a code, show the approval page, wait for the approval. */
    fun signIn(server: String, openUrl: (String) -> Unit) = viewModelScope.launch {
        val url = app.beginSignIn(server) ?: return@launch
        openUrl(url)
        app.finishSignIn()
    }

    fun cancelSignIn() = app.cancelSignIn()

    fun signOut() = viewModelScope.launch {
        stack.clear()
        stack.add(Route.Projects)
        app.signOut()
    }

    override fun onCleared() = app.clearObserver()
}

class ProjectListModel(application: Application) : AndroidViewModel(application) {
    val vm = ProjectListViewModel((application as SamApplication).core)
    private val _state = MutableStateFlow(vm.state())
    val state: StateFlow<ProjectListState> = _state

    init {
        vm.setObserver(object : ProjectListObserver {
            override fun onStateChanged(state: ProjectListState) { _state.value = state }
        })
    }

    fun load() = viewModelScope.launch { vm.load() }

    override fun onCleared() {
        vm.clearObserver()
        vm.close()
    }
}

class ProjectModel(application: Application) : AndroidViewModel(application) {
    val vm = ProjectViewModel((application as SamApplication).core)
    private val _state = MutableStateFlow(vm.state())
    val state: StateFlow<ProjectState> = _state

    init {
        vm.setObserver(object : ProjectObserver {
            override fun onStateChanged(state: ProjectState) { _state.value = state }
        })
    }

    fun load(projectId: String) = viewModelScope.launch { vm.load(projectId) }

    /** Submits, then hands the new session to [open]. */
    fun submit(message: String, open: (sessionId: String) -> Unit, sent: () -> Unit) = viewModelScope.launch {
        vm.submitTask(message)?.let {
            sent()
            open(it.sessionId)
        }
    }

    override fun onCleared() {
        vm.clearObserver()
        vm.close()
    }
}

class ChatModel(application: Application) : AndroidViewModel(application) {
    val vm = ChatViewModel((application as SamApplication).core)
    private val _state = MutableStateFlow(vm.state())
    val state: StateFlow<ChatState> = _state

    init {
        vm.setObserver(object : ChatObserver {
            override fun onStateChanged(state: ChatState) { _state.value = state }
        })
    }

    fun send(content: String, sent: () -> Unit) = viewModelScope.launch {
        if (vm.send(content)) sent()
    }

    override fun onCleared() {
        vm.clearObserver()
        vm.close()
    }
}
