-- ============================================================
-- 01_metrics_views.sql
-- 业务指标视图（第一阶段指标：月度 GMV / 有效订单数）
-- 数据库：SQLite  data/olist.db
-- 依赖表：orders_cleaned（订单主表）、payments（支付流水）
--
-- 运行方式（在 main_analysis.ipynb 中任选其一）：
--   1) 显式 UTF-8 读取后交给 JupySQL（推荐，main_analysis.ipynb 中的 sql-run-file 单元格即此写法）：
--        ddl = Path("sql/01_metrics_views.sql").read_text(encoding="utf-8")
--        %sql {{ ddl }}
--   2) %sql --file ./sql/01_metrics_views.sql
--      注意：JupySQL 内部用 Path.read_text() 不带编码，Windows 默认 GBK 读本文件的 UTF-8
--      中文注释会抛 UnicodeDecodeError；需先设置环境变量 PYTHONUTF8=1（或系统启用 UTF-8 区域设置）
--   3) %%sql 单元格：把本文件内容整段粘贴进去
--   注：%run ./sql/01_metrics_views.sql 不可用（%run 按 Python 语法解析，实测 SyntaxError）
-- ============================================================

-- 视图可重复创建：先删后建，保证脚本可以反复执行
DROP VIEW IF EXISTS v_monthly_gmv;

CREATE VIEW v_monthly_gmv AS

-- ① 有效订单：剔除 canceled（已取消）/ unavailable（缺货未履约）
--    这两类订单虽然部分有支付流水（实测 1,234 笔），但不产生真实成交，不应计入 GMV
--    月份取自 order_purchase_timestamp（下单月），这是电商 GMV 的通用口径
WITH valid_orders AS (
    SELECT order_id,
           strftime('%Y-%m', order_purchase_timestamp) AS order_month
    FROM orders_cleaned
    WHERE order_status NOT IN ('canceled', 'unavailable')
      AND order_purchase_timestamp IS NOT NULL
),

-- ② 先把支付流水按订单聚合
--    一个订单可能有 1~29 行支付记录（信用卡 + 代金券 + 分期）
--    若不先聚合就直接 JOIN，订单行会被放大，COUNT 与 SUM 都会失真
order_paid AS (
    SELECT order_id,
           SUM(payment_value) AS paid_value
    FROM payments
    GROUP BY order_id
)

-- ③ 用 LEFT JOIN 保证「无支付记录的有效订单」也计入订单数，其金额按 0 处理
--    COUNT(DISTINCT order_id)：order_id 本身已唯一、payments 也已预聚合，DISTINCT 作为双保险
SELECT vo.order_month                             AS order_month,
       COUNT(DISTINCT vo.order_id)                AS valid_orders,
       ROUND(SUM(COALESCE(op.paid_value, 0)), 2)  AS gmv
FROM valid_orders vo
LEFT JOIN order_paid op ON op.order_id = vo.order_id
GROUP BY vo.order_month
ORDER BY vo.order_month;

-- 数据质量提示（以下为 orders_cleaned 按月原始订单量，非视图结果）：
--   2016-09（4 单 → 有效 2）、2016-10（324 → 293）、2016-12（1 → 1）、
--   2018-09（16 → 1）、2018-10（4 → 0，全部 canceled/unavailable，故视图中没有该月）
--   属于平台早期测试期尾单 / 数据截断期，量级不具备可比性；
--   做月度趋势或增长率分析时建议加 WHERE order_month BETWEEN '2017-01' AND '2018-08'。
