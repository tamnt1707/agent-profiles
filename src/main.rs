mod secret;
mod store;

use eframe::egui;
use store::{AuthKind, Data, Profile, TerminalApp};

/// Quick-fill templates. Base URLs change over time — check the provider's docs.
const PRESETS: &[(&str, &str, AuthKind)] = &[
    ("Tùy chỉnh", "", AuthKind::Bearer),
    ("OpenRouter", "https://openrouter.ai/api", AuthKind::Bearer),
    ("DeepSeek", "https://api.deepseek.com/anthropic", AuthKind::Bearer),
    ("Kimi (Moonshot)", "https://api.moonshot.ai/anthropic", AuthKind::Bearer),
    ("GLM (Z.ai)", "https://api.z.ai/api/anthropic", AuthKind::Bearer),
    ("MiniMax", "https://api.minimax.io/anthropic", AuthKind::Bearer),
    ("Proxy nội bộ (không key)", "http://localhost:4000", AuthKind::None),
];

fn main() -> eframe::Result<()> {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("Claude Profiles")
            .with_inner_size([920.0, 640.0])
            .with_min_inner_size([720.0, 480.0]),
        ..Default::default()
    };
    eframe::run_native(
        "Claude Profiles",
        options,
        Box::new(|cc| {
            install_fonts(&cc.egui_ctx);
            Ok(Box::new(App::new()))
        }),
    )
}

/// Use a macOS system font first so Vietnamese diacritics always render.
fn install_fonts(ctx: &egui::Context) {
    const CANDIDATES: &[&str] = &[
        "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
        "/Library/Fonts/Arial Unicode.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ];
    let Some(bytes) = CANDIDATES.iter().find_map(|p| std::fs::read(p).ok()) else { return };
    let mut fonts = egui::FontDefinitions::default();
    fonts
        .font_data
        .insert("system".into(), egui::FontData::from_owned(bytes).into());
    for family in [egui::FontFamily::Proportional, egui::FontFamily::Monospace] {
        fonts.families.entry(family).or_default().insert(0, "system".into());
    }
    ctx.set_fonts(fonts);
}

struct Editor {
    /// Index in data.profiles, or None for a new, unsaved profile.
    index: Option<usize>,
    draft: Profile,
    /// New key typed by the user; empty = keep the stored one.
    key_input: String,
    has_stored_key: bool,
    show_key: bool,
}

struct App {
    data: Data,
    editor: Option<Editor>,
    status: Option<(bool, String)>,
    confirm_delete: bool,
}

impl App {
    fn new() -> Self {
        let data = store::load();
        let mut app = Self { data, editor: None, status: None, confirm_delete: false };
        if !app.data.profiles.is_empty() {
            app.select(0);
        }
        app
    }

    fn select(&mut self, i: usize) {
        let draft = self.data.profiles[i].clone();
        let has_stored_key = secret::get(&draft.slug).ok().flatten().is_some();
        self.editor = Some(Editor { index: Some(i), draft, key_input: String::new(), has_stored_key, show_key: false });
        self.confirm_delete = false;
    }

    fn new_profile(&mut self) {
        let draft = Profile { isolate: true, share_from_default: true, ..Default::default() };
        self.editor = Some(Editor { index: None, draft, key_input: String::new(), has_stored_key: false, show_key: false });
        self.confirm_delete = false;
    }

    fn ok(&mut self, msg: impl Into<String>) {
        self.status = Some((true, msg.into()));
    }
    fn err(&mut self, e: impl std::fmt::Display) {
        self.status = Some((false, e.to_string()));
    }

    fn save_current(&mut self) -> bool {
        match self.try_save() {
            Ok(msg) => {
                self.ok(msg);
                true
            }
            Err(e) => {
                self.err(format!("{e:#}"));
                false
            }
        }
    }

    fn try_save(&mut self) -> anyhow::Result<String> {
        let ed = self.editor.as_mut().expect("editor open");
        ed.draft.name = ed.draft.name.trim().to_string();
        ed.draft.slug = store::slugify(&ed.draft.name);
        let others: Vec<Profile> = self
            .data
            .profiles
            .iter()
            .enumerate()
            .filter(|(i, _)| Some(*i) != ed.index)
            .map(|(_, p)| p.clone())
            .collect();
        store::validate(&ed.draft, &others)?;

        if let Some(i) = ed.index {
            store::migrate_slug(&self.data.profiles[i].slug, &ed.draft.slug)?;
        }
        let key = ed.key_input.trim();
        if !key.is_empty() {
            secret::set(&ed.draft.slug, key)?;
            ed.has_stored_key = true;
            ed.key_input.clear();
        }
        if ed.draft.auth != AuthKind::None && !ed.has_stored_key {
            anyhow::bail!("Nhập API key cho profile này (key sẽ được lưu vào Keychain)");
        }
        store::materialize(&ed.draft)?;

        let i = match ed.index {
            Some(i) => {
                self.data.profiles[i] = ed.draft.clone();
                i
            }
            None => {
                self.data.profiles.push(ed.draft.clone());
                self.data.profiles.len() - 1
            }
        };
        ed.index = Some(i);
        store::save(&self.data)?;
        Ok(format!("Đã lưu. Chạy trong terminal bằng lệnh: claude-{}", ed.draft.slug))
    }

    fn delete_current(&mut self) {
        let Some(ed) = self.editor.take() else { return };
        if let Some(i) = ed.index {
            let p = self.data.profiles.remove(i);
            let res = store::remove(&p).and_then(|_| store::save(&self.data));
            match res {
                Ok(()) => self.ok(format!(
                    "Đã xóa \"{}\". Thư mục cấu hình {} vẫn được giữ lại.",
                    p.name,
                    store::home_for(&p.slug).display()
                )),
                Err(e) => self.err(format!("{e:#}")),
            }
        }
        if !self.data.profiles.is_empty() {
            self.select(0);
        }
        self.confirm_delete = false;
    }
}

impl eframe::App for App {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        egui::Panel::top("top").show(ui, |ui| {
            ui.horizontal(|ui| {
                ui.heading("Claude Profiles");
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if ui.button("Mở thư mục").on_hover_text(store::root().display().to_string()).clicked() {
                        let _ = std::fs::create_dir_all(store::root());
                        let _ = std::process::Command::new("open").arg(store::root()).spawn();
                    }
                    let before = self.data.terminal;
                    egui::ComboBox::from_id_salt("term")
                        .selected_text(self.data.terminal.label())
                        .show_ui(ui, |ui| {
                            for t in TerminalApp::ALL {
                                ui.selectable_value(&mut self.data.terminal, t, t.label());
                            }
                        });
                    ui.label("Mở bằng:");
                    if before != self.data.terminal
                        && let Err(e) = store::save(&self.data) {
                            self.err(e);
                        }
                });
            });
        });

        egui::Panel::bottom("status").show(ui, |ui| match &self.status {
            Some((true, m)) => {
                ui.colored_label(egui::Color32::from_rgb(40, 150, 80), m);
            }
            Some((false, m)) => {
                ui.colored_label(egui::Color32::from_rgb(200, 60, 60), m);
            }
            None => {
                ui.weak(format!("Thêm {} vào PATH để gọi claude-<tên> từ mọi terminal.", store::bin_dir().display()));
            }
        });

        egui::Panel::left("list").resizable(false).exact_size(220.0).show(ui, |ui| {
            ui.add_space(6.0);
            if ui.add_sized([ui.available_width(), 28.0], egui::Button::new("＋ Thêm profile")).clicked() {
                self.new_profile();
            }
            ui.separator();
            let current = self.editor.as_ref().and_then(|e| e.index);
            let mut clicked = None;
            egui::ScrollArea::vertical().show(ui, |ui| {
                for (i, p) in self.data.profiles.iter().enumerate() {
                    let resp = ui.selectable_label(current == Some(i), format!("{}\nclaude-{}", p.name, p.slug));
                    if resp.clicked() {
                        clicked = Some(i);
                    }
                }
                if self.data.profiles.is_empty() {
                    ui.weak("Chưa có profile nào.");
                }
            });
            if let Some(i) = clicked {
                self.select(i);
            }
        });

        egui::CentralPanel::default().show(ui, |ui| {
            if self.editor.is_none() {
                ui.centered_and_justified(|ui| {
                    ui.label("Chọn một profile bên trái, hoặc bấm “Thêm profile”.");
                });
                return;
            }
            egui::ScrollArea::vertical().show(ui, |ui| self.editor_ui(ui));
        });
    }
}

impl App {
    fn editor_ui(&mut self, ui: &mut egui::Ui) {
        let mut action_save = false;
        let mut action_launch = false;
        let mut action_delete = false;
        let mut action_copy = None;
        {
            let ed = self.editor.as_mut().unwrap();
            let d = &mut ed.draft;

            if ed.index.is_none() {
                ui.horizontal(|ui| {
                    ui.label("Mẫu nhà cung cấp:");
                    egui::ComboBox::from_id_salt("preset").selected_text("Chọn mẫu…").show_ui(ui, |ui| {
                        for (name, url, auth) in PRESETS {
                            if ui.selectable_label(false, *name).clicked() {
                                if d.name.is_empty() && *name != "Tùy chỉnh" {
                                    d.name = name.to_string();
                                }
                                d.base_url = url.to_string();
                                d.auth = *auth;
                            }
                        }
                    });
                    ui.weak("(URL mẫu: kiểm tra lại trên trang docs của nhà cung cấp)");
                });
                ui.add_space(6.0);
            }

            egui::Grid::new("form").num_columns(2).spacing([12.0, 8.0]).show(ui, |ui| {
                ui.label("Tên profile");
                ui.horizontal(|ui| {
                    ui.add(egui::TextEdit::singleline(&mut d.name).desired_width(260.0).hint_text("vd: GLM"));
                    let slug = store::slugify(&d.name);
                    if !slug.is_empty() {
                        ui.weak(format!("→ lệnh claude-{slug}"));
                    }
                });
                ui.end_row();

                ui.label("Base URL");
                ui.add(
                    egui::TextEdit::singleline(&mut d.base_url)
                        .desired_width(f32::INFINITY)
                        .hint_text("để trống = API gốc của Anthropic"),
                );
                ui.end_row();

                ui.label("Xác thực");
                egui::ComboBox::from_id_salt("auth").selected_text(d.auth.label()).show_ui(ui, |ui| {
                    for a in AuthKind::ALL {
                        ui.selectable_value(&mut d.auth, a, a.label());
                    }
                });
                ui.end_row();

                if d.auth != AuthKind::None {
                    ui.label("API key");
                    ui.horizontal(|ui| {
                        let hint = if ed.has_stored_key { "đã lưu trong Keychain — để trống nếu không đổi" } else { "dán key vào đây" };
                        ui.add(
                            egui::TextEdit::singleline(&mut ed.key_input)
                                .password(!ed.show_key)
                                .desired_width(360.0)
                                .hint_text(hint),
                        );
                        ui.checkbox(&mut ed.show_key, "Hiện");
                        if ed.has_stored_key {
                            ui.label("🔒");
                        }
                    });
                    ui.end_row();
                }

                ui.label("Model chính");
                ui.add(
                    egui::TextEdit::singleline(&mut d.model)
                        .desired_width(f32::INFINITY)
                        .hint_text("ANTHROPIC_MODEL, vd: glm-4.6"),
                );
                ui.end_row();

                ui.label("Thư mục làm việc");
                ui.horizontal(|ui| {
                    ui.add(egui::TextEdit::singleline(&mut d.workdir).desired_width(360.0).hint_text("tùy chọn"));
                    if ui.button("Chọn…").clicked()
                        && let Some(dir) = rfd::FileDialog::new().pick_folder() {
                            d.workdir = dir.display().to_string();
                        }
                });
                ui.end_row();
            });

            ui.add_space(8.0);
            egui::CollapsingHeader::new("Ánh xạ model cho opus / sonnet / haiku").show(ui, |ui| {
                ui.weak("Khi bạn gõ /model opus, sonnet hay haiku trong Claude Code, các tên này sẽ trỏ tới model của nhà cung cấp. Model haiku cũng được dùng cho tác vụ nền.");
                egui::Grid::new("models").num_columns(2).spacing([12.0, 6.0]).show(ui, |ui| {
                    for (label, field) in [
                        ("opus", &mut d.opus_model),
                        ("sonnet", &mut d.sonnet_model),
                        ("haiku", &mut d.haiku_model),
                    ] {
                        ui.label(label);
                        ui.add(egui::TextEdit::singleline(field).desired_width(360.0));
                        ui.end_row();
                    }
                });
            });

            egui::CollapsingHeader::new("Biến môi trường thêm").show(ui, |ui| {
                ui.weak("Mỗi dòng một biến KEY=VALUE. Ví dụ: API_TIMEOUT_MS=600000");
                ui.add(
                    egui::TextEdit::multiline(&mut d.extra_env)
                        .code_editor()
                        .desired_rows(4)
                        .desired_width(f32::INFINITY),
                );
            });

            ui.add_space(8.0);
            ui.checkbox(&mut d.isolate, "Tách riêng cấu hình Claude cho profile này (khuyên dùng)")
                .on_hover_text(format!("CLAUDE_CONFIG_DIR = {}", store::home_for(&store::slugify(&d.name)).display()));
            ui.add_enabled_ui(d.isolate, |ui| {
                ui.checkbox(&mut d.share_from_default, "Dùng chung CLAUDE.md, skills, commands, agents từ ~/.claude");
            });
            ui.weak("Cấu hình gốc ~/.claude và app Claude Desktop không bị thay đổi.");

            ui.add_space(12.0);
            ui.horizontal(|ui| {
                if ui.button("💾 Lưu").clicked() {
                    action_save = true;
                }
                if ui.button("▶ Mở terminal với profile này").clicked() {
                    action_launch = true;
                }
                if ed.index.is_some() {
                    if ui.button("📋 Sao chép lệnh").clicked() {
                        action_copy = Some(format!("claude-{}", d.slug));
                    }
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if self.confirm_delete {
                            if ui.button("Chắc chắn xóa").clicked() {
                                action_delete = true;
                            }
                            if ui.button("Hủy").clicked() {
                                self.confirm_delete = false;
                            }
                        } else if ui.button("🗑 Xóa").clicked() {
                            self.confirm_delete = true;
                        }
                    });
                }
            });

            if let Some(i) = ed.index {
                let saved = &self.data.profiles[i];
                if *saved != ed.draft || !ed.key_input.is_empty() {
                    ui.weak("Có thay đổi chưa lưu.");
                }
            }
        }

        if let Some(text) = action_copy {
            ui.ctx().copy_text(text.clone());
            self.ok(format!("Đã sao chép: {text}"));
        }
        if action_save {
            self.save_current();
        }
        if action_launch && self.save_current() {
            let p = self.editor.as_ref().unwrap().draft.clone();
            match store::launch(&p, self.data.terminal) {
                Ok(()) => self.ok(format!("Đã mở {} với profile \"{}\"", self.data.terminal.label(), p.name)),
                Err(e) => self.err(format!("{e:#}")),
            }
        }
        if action_delete {
            self.delete_current();
        }
    }
}
