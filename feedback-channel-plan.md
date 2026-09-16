# 反馈通道实施计划

分支：`feature/feedback-channel`（从 `main` = `9e488ce` 切出）
产品文档里没有这个模块 —— 它不是 V1 功能清单里的一项，而是为了让**现在这个阶段**能拿到用户反馈而加的一条最短路径。工时估算 0.5–1 天。

---

## 0. 这一版要解决的问题

现在的产品状态是：MMMVP 已上线，邀请码准入正在做，接下来要小范围分发邀请链接给 50–100 人验证流程。
问题是**这批人如果卡住了、觉得哪里别扭、有想法，现在没有任何地方可以说**。页面上唯一的出口是发帖，但"这个网站登录按钮点了没反应"不该变成讨论广场里的一个帖子 —— 它会污染内容质量，而内容质量正是冷启动阶段唯一要守的东西。

所以这一版的唯一目标：**给用户一个和讨论内容分开的、低摩擦的反馈出口，并且让反馈能确实到达团队手里。**

范围刻意收窄到一件事：**登录成员在站内提交一段文字反馈**。

**明确不做**：
- 反馈的状态流转（已读 / 处理中 / 已解决）、给用户回执 —— 现在没有管理后台，反馈量也不会大到需要看板，一条 SQL 就够
- 站内查看自己提交过的反馈历史（连带的"编辑 / 撤回"也不做）
- 内容举报（举报某条帖子/回复）—— 这是另一条工作流，见第 6 节决策点 A
- 截图 / 附件上传（产品文档里"不做富媒体"这条原则同样适用，也省掉 Storage 桶和它的一整套权限）
- 投票式的功能许愿板（Canny 那类）—— 用户量还不到需要"用票数排优先级"的规模
- 自动抓取浏览器环境（见第 6 节决策点 C）

---

## 1. 通道形态：为什么是站内表单，而不是外链表单

摆在桌面上的三个选项：

| 方案 | 成本 | 为什么不选 / 选 |
|---|---|---|
| **Google Form / Tally 外链** | 几乎为零 | 反馈要填一遍身份、跳出站外、表单会自己收一份邮箱，等于在数据库层之外**又开一个存用户身份的地方**，和这个项目"身份边界靠数据库权限强制"的做法拧着。另外它会给用户一个"这个产品是临时拼的"的信号 |
| **第三方反馈组件**（Canny / Usersnap） | $0–50/月 + 一段第三方脚本 | 要往页面里塞一个会自己发请求的外部脚本，且当前规模完全用不上它的功能。运营成本表里也没有这一项 |
| **✅ 站内表单 → Supabase 只写表** | 半天开发，零新增依赖、零新增密钥、零新增账单 | 复用已经跑通的 Auth + RLS + grant 模式；反馈落在自己的库里，跟讨论内容同一套权限模型；README 里"管理操作直接在 Supabase dashboard 做"这条已有约定天然覆盖它 |

所以：**站内表单 + 一张只允许 insert 的 `feedback` 表**。

### 一个不能忽略的缺口：登不进来的人怎么反馈？

站内表单只对登录成员开放，但**冷启动阶段最值钱的一条反馈恰恰是「我登不进去」**（尤其邀请码门槛合入之后，会多出一整类"码不对/码过期"的失败）。这类用户永远看不到站内表单。

对策：**登录页放一个 `mailto:` 链接**，不走数据库。
理由是给 `anon` 角色开 insert 权限意味着开一个任何人都能匿名往库里写字符串的公开写入端点，为了这一类反馈引入一个需要防刷的攻击面不划算。邮件这条路零代码、零权限改动、也不会被刷（收件箱本来就有反垃圾）。

代价：登录页反馈会流进某个人的邮箱，取决于用谁的地址（见第 6 节决策点 B）。

---

## 2. 匿名模型：反馈通道会不会成为一个后门

这是必须先想清楚的一条，因为整个产品的信任基础是「匿名保护做在数据库层，不靠前端自觉」。三条硬规则：

1. **反馈是实名的，且这不违反匿名承诺**。匿名保护的对象是**帖子**，不是用户的每一个动作。反馈里存 `author_id`（沿用 `posts` / `replies` 的写法：保留给运营，但对 Data API **完全不给 SELECT 权限**），这样团队能追问细节，也能识别恶意刷提交。
2. **不做任何"页面上下文"的自动采集**。技术上很容易在提交时顺手把"用户当前展开了哪些帖子"带上去 —— 一旦这么做，一个匿名帖作者随手提一句反馈，就在 `feedback` 表里留下了「这个身份 ↔ 这些帖子」的关联。这条链路必须从设计上不存在，而不是靠"我们不会去看"。所以：**只提交用户自己敲进去的文字**，见第 6 节决策点 C。
3. **`feedback` 表对所有客户端角色都没有 SELECT 权限，包括提交者自己**。只有 `service_role` / dashboard 能读。这样就不存在"读到别人反馈"这个类别的漏洞 —— 不是靠 RLS 过滤得对，而是**这张表在 Data API 上根本没有读的入口**。

顺带一条自觉性约定，写进迁移注释：用户在反馈正文里主动写"我发的那个帖子……"，会把自己的身份和帖子关联起来，这是用户自己的选择，团队不去做这个关联。但**不要**因此在表上加 `post_id` 之类的结构化字段去承接它 —— 一旦结构化，就从"用户偶然提到"变成"系统按设计收集"，性质完全不同。

---

## 3. 数据库改动

新增迁移 `supabase/migrations/2026XXXXXXXXXX_add_feedback_channel.sql`，沿用现有迁移风格：先 `revoke all`，再按列逐个 `grant`。

### `feedback`

| 列 | 说明 |
|---|---|
| `id` | identity 主键 |
| `author_id` | `uuid not null default auth.uid() references auth.users (id) on delete cascade`。**不给客户端 SELECT 权限**，和 `posts.author_id` 一致 |
| `kind` | `check (kind in ('bug', 'idea', 'other'))`，默认 `'other'`。刻意只有三类，够用且不需要用户思考 |
| `body` | `text not null`，`check (body = btrim(body) and char_length(body) between 1 and 2000)`，和 `replies.body` 同一个上限 |
| `can_contact` | `boolean not null default true`。"可以就这条反馈联系我" |
| `created_at` | `timestamptz not null default now()` |

**不存邮箱。** 用户的邮箱已经在 `auth.users` 里，dashboard 里 join 一下就有；在业务表里再抄一份 PII 是纯粹的负债。`can_contact` 只是一个意愿开关。

权限与策略：

- `revoke all on table public.feedback from anon, authenticated`，`revoke all on sequence public.feedback_id_seq from anon, authenticated`
- 只 `grant insert (kind, body, can_contact) on table public.feedback to authenticated` + `grant usage, select on sequence public.feedback_id_seq to authenticated`
- **不建任何 select 策略、不给任何 select 权限**
- `enable row level security`，只写一条 insert 策略，沿用现有迁移的 Google provider 校验写法：
  `(select auth.uid()) = author_id and coalesce((select auth.jwt()) -> 'app_metadata' ->> 'provider', '') = 'google'`
- 索引：`(created_at desc, id desc)`，给 dashboard 按时间翻用；`(author_id)` 给排查刷提交用

### 防刷：一个 `before insert` 触发器

反馈表是全站唯一一个"用户可写、但没人在前台看得见"的地方 —— 没有社交压力，也没有人会发现有人在往里灌垃圾，所以必须在库里挡：

`enforce_feedback_rate_limit()` —— `before insert on public.feedback`，同一 `author_id` 在过去 1 小时内已有 5 条则 `raise exception`。
写法照抄 `strip_anonymous_reply_identity`：`language plpgsql`、`security definer`、`set search_path = ''`、`revoke all on function ... from public, anon, authenticated`。

前端要认这个报错并给一句人话（"今天的反馈够多了，先让我们消化一下 🙂"），不能把 Postgres 的原始异常直接弹给用户 —— `friendlyError()` 里加一条匹配即可。

---

## 4. 前端改动

### `index.html`

1. **topbar**：在 `.account-menu` 里、账号名左侧加一个 `.text-button`「反馈」，`aria-haspopup="dialog"`。
2. **反馈弹层**：用原生 `<dialog id="feedback-dialog">`（免费拿到焦点陷阱、Esc 关闭、`::backdrop`、返回焦点），内含 `kind` 的三个 radio、`body` textarea（`maxlength="2000"`）、`can_contact` checkbox、取消 / 提交两个按钮。
3. **登录页**：`.privacy-note` 下面加一行 `mailto:` 链接「登录遇到问题？写信告诉我们」。

> ⚠️ 与 `feature/notification-center`（铃铛也加在 `.account-menu`）和 `feature/invite-code-gate`（改登录页）都会在同一段 HTML 上冲突。都是几行的手工冲突，但**合入顺序上后合的那个要复查 topbar 的最终顺序**：期望是 `铃铛 · 反馈 · 账号名 · 退出`，别让反馈按钮挤到铃铛和名字中间。

### `src/lib.js`（纯函数，便于 `node --test` 覆盖）

- `FEEDBACK_KINDS` —— 三类的 value + 中文标签，UI 和校验共用一个源
- `validateFeedback(kind, body)` —— 严格照 `validatePost` / `validateReply` 的返回形状 `{ ok, value | message }`；正文 trim 后为空、超 2000 字、`kind` 不在白名单（回落到 `'other'`）
- `LIMITS` 里加 `feedbackMax: 2000`

### `src/app.js`

- `elements` 里补上新节点（保持现有的字母序）
- 「反馈」按钮 → `dialog.showModal()`；提交走 `validateFeedback` → `backend.createFeedback()` → 复用 `setButtonBusy` / `showToast('收到了，谢谢。')` / `friendlyError`
- 成功后 `form.reset()` + `dialog.close()`；失败**保留用户已经写的内容**不清空（写了 500 字被网络错误清掉一次，这个用户就再也不会给第二次反馈了）
- textarea 复用现有的字数计数模式

### `src/backend.js`

- Supabase 实现：`createFeedback({ kind, body, can_contact })` → `insert()`，**不带 `.select()`**（表上没有 SELECT 权限，一旦 `.select()` 就必然报错）
- demo 实现：写进 `localStorage`。demo 后端是现在唯一能不接 Supabase 就演示 UI 的路径，不能让 `?demo=1` 下的反馈弹层变成一个点了没反应的死控件

### `src/styles.css`

`dialog` + `::backdrop` + radio 行 + 提交行，令牌全部取自 `design-tokens.css`，不新增 hex。

**配色规则**（`CLAUDE.md`）：
- 「反馈」入口用现有 `.text-button`，**保持中性**。不做右下角悬浮彩色按钮 —— 那是装饰性用色，且会永久盖住一块内容
- 弹层：`--surface` 底 + `--border` 发丝线 + `--text` 正文，选中的 radio 用 `--brand-tint` 底
- 提交按钮复用 `.primary-button`（已经是 `--brand`）
- **「反馈问题」不是 `--risk` 的适用场景**。红色只留给真实风险，一个用户主动说"这里有点别扭"不是风险，是好事

---

## 5. 落地顺序与验证

| # | 步骤 | 产出 |
|---|---|---|
| 1 | 迁移：表 + 权限 + RLS + 限流触发器 | 后端已可接收，可用 curl 先验证权限 |
| 2 | `lib.js` 校验函数 + `test/lib.test.js` 用例 | `npm test` 绿 |
| 3 | demo 后端 `createFeedback` | `?demo=1` 下能点通完整交互 |
| 4 | `<dialog>` + topbar 入口 + 样式 | 站内闭环 |
| 5 | 登录页 `mailto:` 回退 | 登不进来的人也有出口 |
| 6 | README 加一节「怎么读反馈」（一条 dashboard SQL）+ `product_design_summary.md` 进度段补一行 | 可合并 |

一个 PR 就够，不用拆。

验证（现有口径 `npm test` + `npm run build`）之外，手动确认五件事：

1. 用 publishable key 直接打 Data API `select` `feedback` —— **必须失败**（不是"返回空数组"，是没有权限）
2. 提交一条，dashboard 里能看到，且 `author_id` 对得上
3. 一小时内连提 6 条 —— 第 6 条被拒，且页面上是人话不是 Postgres 异常
4. 键盘走完全程：Tab 到「反馈」→ Enter 打开 → Tab 到 textarea → 提交 → 焦点回到「反馈」按钮
5. 深色模式（`design-tokens.css` 有 `prefers-color-scheme` 分支）下弹层和 backdrop 正常

---

## 6. 开工前需要你确认的三个决策

**A. 这一版要不要带内容举报？**
- 不带（建议）：只有一个通用反馈入口。用户想举报也可以在正文里写，团队照样看得到
- 带：每张帖子/回复卡片上多一个「举报」入口 + 表上加 `post_id` / `reply_id`。UI 面积、结构化字段、以及第 2 节那条"不要结构化地把身份和帖子关联起来"的顾虑全都跟着来
我的建议：**不带**。现在是几十人的邀请制熟人社区，先看看真的有没有需要举报的东西，再决定要不要为它建结构。

**B. 登录页的 `mailto:` 用哪个地址？**
需要一个能公开写进 HTML 的地址（会被爬虫抓到、会收到垃圾邮件），别用团队成员的个人主邮箱。
我的建议：**新开一个 `feedback@`（或先用一个转发别名）**，登录页和 README 都指向它。这个地址定下来我才能写进代码。

**C. 反馈要不要附带浏览器信息？**
- 什么都不附（建议）：只有用户写的文字。排查 bug 时可能得回头问一句"你用的什么浏览器"
- 附 `user_agent` + 页面路径：bug 好查，但这是团队自己给自己开的一次被动采集，也和第 2 节那条原则的精神相反
我的建议：**什么都不附**，`can_contact` 已经给了追问的路。真到了"反馈里一半是查不下去的 bug"那天再加，并且加的时候在弹层里明写「会一起发送这些信息」。
