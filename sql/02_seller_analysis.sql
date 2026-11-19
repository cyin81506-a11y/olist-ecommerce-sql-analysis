-- ============================================================
-- 02_seller_analysis.sql
-- 专题分析：卖家履约质量 与 差评率 的关联
-- 数据库：SQLite  data/olist.db
-- 依赖表：order_items（订单明细 / seller_id）、orders_cleaned（订单主表 / 时间字段）、
--         reviews（评论 / review_score）
-- 产出：v_seller_base（订单×卖家明细）、v_seller_metrics（卖家指标 + 差评率四分位）
--       文件末尾的最终查询按 4 个等级对比履约时效、客单价、订单量
--
-- 运行方式（在 main_analysis.ipynb 中，见第五阶段 stage5-run-file 单元格）：
--   seller_sql = Path("sql/02_seller_analysis.sql").read_text(encoding="utf-8")
--   %sql {{ seller_sql }}
-- 注意：本文件含 UTF-8 中文注释，不要用 %sql --file（JupySQL 内部按系统默认 GBK 读取会报
--       UnicodeDecodeError），也不要用 %run（按 Python 语法解析会报 SyntaxError）。
-- 备选：engine.raw_connection().executescript(seller_sql) 只建视图，再单独 %sql 查询结果。
-- ============================================================


-- ------------------------------------------------------------
-- 视图 1：v_seller_base —— 订单 × 卖家 粒度明细
-- ------------------------------------------------------------
DROP VIEW IF EXISTS v_seller_base;

CREATE VIEW v_seller_base AS

-- ① 订单 × 卖家 聚合
--    order_items 是「一行一个商品」，同一订单可能有多件商品、也可能涉及多个卖家
--    （实测 98,666 个下单订单中 1,278 个为多卖家订单，占 1.3%）
--    先聚合到「订单 × 卖家」粒度，才能保证订单数不被商品行数放大；
--    金额口径 = 该卖家在该订单中承担的 price + freight_value 合计
WITH item_pair AS (
    SELECT order_id,
           seller_id,
           SUM(price + freight_value) AS pair_amount,   -- 该卖家在该订单的成交金额（含运费）
           COUNT(*)                   AS item_count     -- 商品件数
    FROM order_items
    GROUP BY order_id, seller_id
),

-- ② 评论去重
--    实测 reviews 有 547 个订单存在多条评论（其中 202 个订单的多条评论分数互相矛盾），
--    若不去重会让这些订单在差评率里被重复计数；
--    口径：同一订单取「最后一次回复时间」最新的那条评论，代表客户最终评价
review_dedup AS (
    SELECT order_id, review_score
    FROM (
        SELECT order_id,
               review_score,
               ROW_NUMBER() OVER (
                   PARTITION BY order_id
                   ORDER BY review_answer_timestamp DESC,   -- 优先取最新回复
                            review_creation_date  DESC      -- 回复时间相同则取后创建
               ) AS rn
        FROM reviews
    )
    WHERE rn = 1
)

SELECT ip.order_id,
       ip.seller_id,
       ip.pair_amount,
       ip.item_count,
       o.order_status,
       o.order_purchase_timestamp,
       o.order_delivered_carrier_date,
       -- 发货时长（小时）= 承运商揽收时间 − 客户下单时间
       -- 用 julianday() 求天数差再 ×24 换成小时
       (julianday(o.order_delivered_carrier_date) - julianday(o.order_purchase_timestamp)) * 24.0 AS ship_hours,
       rd.review_score
FROM item_pair ip
JOIN orders_cleaned o
  ON o.order_id = ip.order_id
LEFT JOIN review_dedup rd
  ON rd.order_id = ip.order_id
-- 剔除已取消 / 缺货未履约：这两类订单不产生真实成交，也不应有履约时效
WHERE o.order_status NOT IN ('canceled', 'unavailable');


-- ------------------------------------------------------------
-- 视图 2：v_seller_metrics —— 卖家维度指标 + NTILE(4) 差评率分级
-- ------------------------------------------------------------
DROP VIEW IF EXISTS v_seller_metrics;

CREATE VIEW v_seller_metrics AS

WITH seller_stats AS (
    SELECT seller_id,
           -- 总订单量：每个「订单×卖家」组合算 1 单
           COUNT(*)                             AS total_orders,
           -- 有评论的订单数：作为差评率的分母，避免无评论订单稀释差评率
           COUNT(review_score)                  AS reviewed_orders,
           -- 平均发货时长（小时）
           -- 只统计 0 ~ 1440 小时（60 天）区间：实测 166 单揽收时间早于下单时间（负值，数据错误），
           -- 另有 6 单超过 60 天（极端异常），都会污染平均值，故一并剔除
           AVG(CASE WHEN (julianday(order_delivered_carrier_date) - julianday(order_purchase_timestamp)) * 24.0
                         BETWEEN 0 AND 1440
                    THEN (julianday(order_delivered_carrier_date) - julianday(order_purchase_timestamp)) * 24.0
               END)                             AS avg_ship_hours,
           -- 差评率 = review_score <= 2 的订单数 / 有评论的订单数
           -- 分母用 NULLIF 防止除零；没有评论的卖家结果为 NULL 而不是 0
           ROUND(1.0 * SUM(CASE WHEN review_score <= 2 THEN 1 ELSE 0 END)
                 / NULLIF(COUNT(review_score), 0), 4) AS bad_review_rate,
           -- 平均单笔成交金额（price + freight_value），供最终分组对比使用
           ROUND(AVG(pair_amount), 2)           AS avg_order_value
    FROM v_seller_base
    GROUP BY seller_id
    -- 订单量下限：实测 571 个卖家只有 1 单、872 个只有 2~5 单，
    -- 这类卖家差评率非 0 即 1，会把四分位边界拉向极端值；这里保留 ≥10 单的卖家（1,261 个，覆盖 93,509 单）
    HAVING COUNT(*) >= 10
)

SELECT seller_id,
       total_orders,
       reviewed_orders,
       -- 评论覆盖率：用于判断该卖家差评率是否可信（覆盖率过低时差评率波动大）
       ROUND(1.0 * reviewed_orders / total_orders, 4) AS review_coverage,
       ROUND(avg_ship_hours, 2)                        AS avg_ship_hours,
       bad_review_rate,
       avg_order_value,
       -- 按差评率升序切成 4 等份：1 = 差评率最低（最优），4 = 差评率最高（最差）
       -- 同级差评率可能相同（实测有 100 个卖家差评率为 0），
       -- 追加 total_orders DESC, seller_id 作为次序键，保证每次运行分组结果完全一致
       NTILE(4) OVER (ORDER BY bad_review_rate ASC,
                               total_orders DESC,
                               seller_id ASC) AS quality_tier
FROM seller_stats;


-- ------------------------------------------------------------
-- 最终查询：4 个差评率等级的分组对比
-- 说明：这里的「平均」按订单加权（即该等级下所有订单的均值），
--       而不是「卖家均值的均值」，避免小卖家与大卖家被等同对待
-- ------------------------------------------------------------
SELECT m.quality_tier                                        AS quality_tier,
       COUNT(DISTINCT m.seller_id)                           AS seller_count,
       -- 订单量从订单×卖家明细逐行计数；若写成 SUM(m.total_orders)，
       -- 该值会被 b 的每行重复带出，结果等于各卖家订单数的平方和（严重虚高）
       COUNT(b.order_id)                                     AS total_orders,
       ROUND(AVG(CASE WHEN b.ship_hours BETWEEN 0 AND 1440
                      THEN b.ship_hours END), 2)             AS avg_ship_hours,
       ROUND(AVG(b.pair_amount), 2)                          AS avg_order_value,
       ROUND(100.0 * SUM(CASE WHEN b.review_score <= 2 THEN 1 ELSE 0 END)
             / NULLIF(COUNT(b.review_score), 0), 2)          AS bad_review_rate_pct
FROM v_seller_metrics m
JOIN v_seller_base b
  ON b.seller_id = m.seller_id
GROUP BY m.quality_tier
ORDER BY m.quality_tier;

-- 结果解读要点（实测数据）：
--   tier 1（差评率最低 0~7.8%）平均发货 57.7 小时、差评率 5.03%
--   tier 4（差评率最高 18.2%+）平均发货 109.1 小时、差评率 24.05%
--   → 发货时长越短，差评率越低，履约时效与差评率存在明显正相关（约 1.9 倍差距）
--   边界并列说明：tier 3 与 tier 4 的分界值 0.1818 存在大量并列卖家，
--   NTILE 按 total_orders DESC, seller_id ASC 兜底拆分，保证结果可复现。
