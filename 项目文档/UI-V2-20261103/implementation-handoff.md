# 实现交接（implementation-handoff.md）

> 给下一个动手改代码的人/Agent。看完这份 + `DESIGN.md` 就能开工，不需要再问。
> **本轮不改代码**，本文只是施工单。

## 0. 先读什么

| 读 | 目的 |
|---|---|
| `项目文档/UI-V2-20261103/DESIGN.md` | 所有取值（色/字/间距/组件）以它为准 |
| `项目文档/UI-V2-20261103/提案评审与页面清单.md` | 哪几屏做、哪几屏不做、逐屏改什么 |
| `项目文档/UI-V2-20261103/参考图/*.jpg` | 视觉基准（15 张，按 01–15 编号） |
| `app/entry/src/main/ets/pages/ChatMain.ets` | 最复杂的对话页，先理解状态再动 UI |
| `app/entry/src/main/ets/pages/Index.ets` | 四个 tab 的宿主页 |
| `app/entry/src/main/ets/utils/DeviceLayout.ets` | 大屏最大宽度，已有能力直接用 |
| `app/entry/src/main/ets/components/PageHeader.ets` | 现有共享页头，作为 `AppHeader` 的起点 |

## 1. 三步准备（不动业务逻辑）

1. **色板落资源**：`resources/base/element/color.json` 增加 `DESIGN.md §2.1` 的 19 个令牌，命名用下划线（`brand_primary`）。页面里改成 `$r('app.color.xxx')`。
   - 只按语义替换，不要全局 sed。`#2563EB` 是主色，但 `#EF4444`/`#0F766E`/Canvas 里的色值要单独判断。
2. **数值落常量**：新建 `ets/theme/Theme.ets`，导出 `Space`、`Radius`、`FontSize`、`LineHeight` 静态常量；只放数值，不放颜色（颜色走资源，才能以后加 dark）。
3. **图标落资源**：`resources/base/media/` 放 24×24 线性 SVG（`currentColor`），用 `.fillColor()` 染色。至少 30 个：返回、更多、搜索、加号、勾、关闭、箭头、课程、作业、错题、知识库、计划、目标、专注、计时、报告、搭子、消息、提醒、设置、账号、隐私、上传、文件、图片、语音、发送、刷新、同步、设备、卡片。
   - 没有的先用系统 `SymbolGlyph($r('sys.symbol.xxx'))`，不要用 emoji 顶。

## 2. 组件顺序（先有组件，再改页面）

按 `DESIGN.md §6` 建，顺序即依赖顺序：

`StateView` → `StatusPill` → `ListRow` → `InfoCard` → `SectionHeader` → `PrimaryButton`/`SecondaryButton` → `Metric` + `ProgressRow` → `AppHeader` + `PageScaffold` → `SegmentedTabs` → `BottomActionBar` → `SheetShell` → `AppTabBar`（合并 `ChatMain`/`Index` 两套）。

**硬约束**：

- 一律 `@Component` + `@Prop/@Link`，不要用带状态参数的 `@Builder`（`ChatMain.ets` 里已有踩坑注释：@Builder 按值传参，选中态不刷新）。
- `AppTabBar` 抽出后，`ChatMain` 与 `Index` 各删一套内联 TabItem，只保留路由切换逻辑。
- 不要在组件里读 `appState`；展示数据由页面传入。

## 3. 页面顺序（按演示路径，不按提案编号）

### P0 · 先证明风格（约 5–7 人日）

1. `pages/Login`（11A/11B）—— 第一屏，最快看出改版成败。
2. `pages/ChatMain`（01A/02A/15C）—— 首页主张 + 主卡 + 输入框；删 hero 40vp。
3. `pages/Index` tab1/2/3（01B/01C/01D）—— 智能体列表化、学习列表化、我的分组。
4. `pages/CourseImport`（05A/05B）—— 列表行 + 状态 pill 的样板。
5. `pages/StudyPlan`（06A）—— 时间轴/计划的排布。

> 检查点：这 5 屏做完，先出一组 393×852 截图与提案并排对比，确认「密度、字号、层级」方向没跑偏，再继续。

### P1 · 主线纵深（约 8–10 人日）

6. `pages/WrongQuestion`（03A/03B）→ `pages/ExercisePractice`（04A/04B/04C/04D）
7. `pages/FocusSetup` → `FocusTimer` → `FocusResult`（07A/B/C）
8. `pages/TaskDetail`（06D）、`pages/ReviewSummary`（10A）
9. `pages/KnowledgeBase`（08A–08D，只改列表与文档卡，正文核对区 P2）
10. `pages/Account` + `EditProfile`（12A/12C）+ `Reminders`（12B，与 14A 合并）
11. `pages/PartnerMatch` / `PartnerChat` / `PartnerInbox`（09、15A/B）

> 检查点：P1 结束应能完整走完「导入课程 → 生成计划 → 开始专注 → 做题 → 看报告」而不回退到旧样式。

### P2 · 状态与长尾（约 4–6 人日）

12. 用 `StateView` 覆盖 14B/14C/14D 的等待、失败、冲突、恢复、时间不足（能复用就不新建页面）。
13. `pages/WrongBook`（13C/13D）、`pages/AgentTrace`（12D）、`pages/UpcomingExams`（10D）、`pages/LearningReview`（10B）、`pages/LearningSetup`（10C）。
14. `pages/KnowledgeCatalog`（03D）、`pages/StudyTags`（03C）。

### 不做（本轮）

- `pages/ApiEnvironment`（13B 调试页）：保持原样，只确保入口藏在「关于 → 连点版本号」。
- 多设备/桌面卡片页（13A）：只在「我的」里保留一条入口指向现有设备状态，不新建页面。
- 深色模式、动效体系、图标全量重绘（除上面 30 个必需项）。

## 4. 三档排期（按剩余时间选一档）

| 可用时间 | 做到哪 | 预期效果 |
|---|---|---|
| ≤1 周（1–2 人） | 只做 §2 组件 + P0 五屏 | 首页/登录/学习/课程明显焕新；其余页仍是旧样式，需统一改主色与字号，避免割裂 |
| 2 周（2 人） | 组件 + P0 + P1 | 演示主线全部新样式，状态页只做 3 个高频的 |
| 3 周+（2–3 人） | P0+P1+P2 | 接近提案完成度；仍不建议逐屏复刻 60 屏 |

## 5. 验收（每屏都要过）

- [ ] 393×852 / 360×780 两档截图，主标题不折行、按钮不出屏、底部栏不被手势条压住。
- [ ] 从入口点到该页、再返回，原路径功能不变（导入、提交、保存、返回都有反馈）。
- [ ] 页面内不再出现硬编码颜色/圆角/间距（除 0 与 100%）。
- [ ] 空态/加载/错误三种状态都能看到（用夹具或断网触发）。
- [ ] 一屏一个主按钮、一个主色、一个大数字。
- [ ] 平板 1280vp 下内容居中且不超 720vp。

## 6. 第一件产物应该证明什么

用 `Login` + `ChatMain` + `Index(学习 tab)` 三屏，证明这四件事，再谈铺开：

1. 密度提升后**没有变挤**（行高、留白、触控区仍舒服）。
2. 主色换成 `#1151D8` 后，**状态色不打架**（逾期红/需巩固橙/完成绿同屏仍清楚）。
3. 列表化之后，**原有关键入口没丢**（开始专注、课程与 DDL、错题本、知识库仍一步可达）。
4. 页头/底栏统一后，**页面之间切换不跳**（标题位置、返回方式一致）。
