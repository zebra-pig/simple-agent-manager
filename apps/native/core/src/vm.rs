//! Boilerplate every view model shares: a state snapshot behind a mutex, the
//! shell's observer (a UniFFI callback interface), `state()` for first paint,
//! and `update()` which mutates and pushes the new snapshot.

/// `observable!(Vm, State, Observer)` declares `Observer` and `Vm { app, inner }`
/// with `new(app)`, `set_observer`, `clear_observer`, `state` exported, and a
/// private `update(|s| ...)`. Intents go in a separate `#[uniffi::export]` impl.
macro_rules! observable {
    ($vm:ident, $state:ty, $observer:ident) => {
        #[uniffi::export(callback_interface)]
        pub trait $observer: Send + Sync {
            fn on_state_changed(&self, state: $state);
        }

        #[derive(uniffi::Object)]
        pub struct $vm {
            app: std::sync::Arc<crate::session::App>,
            inner: std::sync::Mutex<($state, Option<std::sync::Arc<dyn $observer>>)>,
        }

        #[uniffi::export]
        impl $vm {
            #[uniffi::constructor]
            pub fn new(app: std::sync::Arc<crate::session::App>) -> std::sync::Arc<Self> {
                std::sync::Arc::new(Self { app, inner: std::sync::Mutex::new((<$state>::default(), None)) })
            }
            pub fn set_observer(&self, observer: Box<dyn $observer>) {
                self.inner.lock().unwrap().1 = Some(std::sync::Arc::from(observer));
            }
            pub fn clear_observer(&self) {
                self.inner.lock().unwrap().1 = None;
            }
            pub fn state(&self) -> $state {
                self.inner.lock().unwrap().0.clone()
            }
        }

        impl $vm {
            #[allow(dead_code)]
            fn update(&self, f: impl FnOnce(&mut $state)) {
                let (snapshot, observer) = {
                    let mut g = self.inner.lock().unwrap();
                    f(&mut g.0);
                    (g.0.clone(), g.1.clone())
                };
                if let Some(o) = observer {
                    o.on_state_changed(snapshot);
                }
            }
        }
    };
}
