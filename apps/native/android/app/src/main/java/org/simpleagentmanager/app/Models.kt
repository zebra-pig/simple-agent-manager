package org.simpleagentmanager.app

import android.app.Application
import android.net.Uri
import androidx.compose.runtime.mutableStateListOf
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import org.simpleagentmanager.core.AppObserver
import org.simpleagentmanager.core.AppState
import org.simpleagentmanager.core.AuthStatus
import org.simpleagentmanager.core.ChatObserver
import org.simpleagentmanager.core.ChatState
import org.simpleagentmanager.core.ChatViewModel
import org.simpleagentmanager.core.ProfileDraft
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
    data object Assistant : Route
    data object Notifications : Route
    data object Projects : Route
    data object Account : Route
    data class ProjectSettings(val projectId: String?) : Route
    data class Project(val id: String, val name: String) : Route
    data class Chat(val projectId: String, val sessionId: String) : Route
    /** The profile editor; `profileId` null for a new profile. */
    data class ProfileEditor(val projectId: String, val profileId: String?) : Route
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

    /** Attaches picked or dropped files to the next task; each uploads right away. */
    fun attach(uris: List<Uri>) = uris.forEach { uri ->
        viewModelScope.launch(Dispatchers.IO) {
            val file = getApplication<Application>().contentResolver.describe(uri)
            vm.addAttachment(file.name, file.contentType, file.size.toULong(), file.source)
        }
    }

    fun detach(id: String) = vm.removeAttachment(id)

    /** The next task runs with this agent profile. */
    fun selectProfile(id: String) = vm.selectProfile(id)

    /** The editor opened: agents to choose from, last error cleared. */
    fun loadAgents() = viewModelScope.launch { vm.loadAgents() }

    /** Creates (`profileId` null) or updates a profile; [done] runs when it was saved. */
    fun saveProfile(profileId: String?, draft: ProfileDraft, done: () -> Unit) = viewModelScope.launch {
        if (vm.saveProfile(profileId, draft)) done()
    }

    fun deleteProfile(profileId: String, done: () -> Unit) = viewModelScope.launch {
        if (vm.deleteProfile(profileId)) done()
    }

    /** Submits, then hands the new session to [open]. */
    fun submit(message: String, open: (sessionId: String) -> Unit, sent: () -> Unit) = viewModelScope.launch {
        vm.submitTask(message)?.let {
            sent()
            open(it.sessionId)
            vm.finishSubmission(it.sessionId)
        }
    }

    override fun onCleared() {
        vm.clearObserver()
        vm.close()
    }
}

class ChatModel(application: Application) : AndroidViewModel(application) {
    val app = (application as SamApplication).core
    val tools = org.simpleagentmanager.core.ChatToolsViewModel((application as SamApplication).core)
    private val _toolsState = MutableStateFlow(tools.state())
    val toolsState: StateFlow<org.simpleagentmanager.core.ChatToolsState> = _toolsState

    val vm = ChatViewModel((application as SamApplication).core)
    private val _state = MutableStateFlow(vm.state())
    val state: StateFlow<ChatState> = _state

    init {
        tools.setObserver(object : org.simpleagentmanager.core.ChatToolsObserver {
            override fun onStateChanged(state: org.simpleagentmanager.core.ChatToolsState) { _toolsState.value = state }
        })
        vm.setObserver(object : ChatObserver {
            override fun onStateChanged(state: ChatState) { _state.value = state }
        })
    }

    /** Attaches picked or dropped files to the next follow-up; each uploads right away. */
    fun attach(uris: List<Uri>) = uris.forEach { uri ->
        viewModelScope.launch(Dispatchers.IO) {
            val file = getApplication<Application>().contentResolver.describe(uri)
            vm.addAttachment(file.name, file.contentType, file.size.toULong(), file.source)
        }
    }

    fun detach(id: String) = vm.removeAttachment(id)

    fun send(content: String, result: (Boolean) -> Unit) = viewModelScope.launch {
        result(vm.send(content))
    }

    override fun onCleared() {
        tools.clearObserver()
        tools.close()
        vm.clearObserver()
        vm.close()
    }
}

class ProjectManagementModel(application: Application) : AndroidViewModel(application) {
    val vm = org.simpleagentmanager.core.ProjectManagementViewModel((application as SamApplication).core)
    private val _state = MutableStateFlow(vm.state())
    val state: StateFlow<org.simpleagentmanager.core.ProjectManagementState> = _state
    init {
        vm.setObserver(object : org.simpleagentmanager.core.ProjectManagementObserver {
            override fun onStateChanged(state: org.simpleagentmanager.core.ProjectManagementState) { _state.value = state }
        })
    }
    fun load(id: String?) = viewModelScope.launch { vm.load(id) }
    fun repositories(provider: String, installation: String, search: String) = viewModelScope.launch {
        vm.loadRepositories(provider, installation, search)
    }
    fun save(draft: org.simpleagentmanager.core.ProjectDraft, done: (org.simpleagentmanager.core.Project?) -> Unit) = viewModelScope.launch {
        vm.save(draft)?.let(done)
    }
    fun delete(confirmation: String, done: (org.simpleagentmanager.core.Project?) -> Unit) = viewModelScope.launch {
        if (vm.delete(confirmation)) done(null)
    }
    override fun onCleared() { vm.clearObserver(); vm.close() }
}
