-- Практика 10. Транзакции, MVCC, блокировки
-- Два подключения: сеанс A и сеанс B. Исходно: счёт 1 = 1000, счёт 2 = 500, сумма 4550.

-- 0. Контроль
SELECT pg_backend_pid() AS session_pid;                                   -- в A и в B разные
SELECT COUNT(*) AS accounts_count FROM l10_accounts;                      -- 5
SELECT COUNT(*) AS tasks_count FROM l10_tasks;                            -- 10
SELECT account_id, balance FROM l10_accounts WHERE account_id IN (1, 2);  -- 1000, 500
SELECT SUM(balance) AS total_balance FROM l10_accounts;                   -- 4550

-- 1. Перевод 100 со счёта 1 на счёт 2 (сеанс A)
BEGIN;
UPDATE l10_accounts SET balance = balance - 100
WHERE account_id = 1 AND balance >= 100
RETURNING account_id, balance;                  -- 1 | 900
UPDATE l10_accounts SET balance = balance + 100
WHERE account_id = 2
RETURNING account_id, balance;                  -- 2 | 600
SELECT SUM(balance) FROM l10_accounts;          -- 4550
COMMIT;

-- 2. ROLLBACK (сеанс A)
SELECT balance FROM l10_accounts WHERE account_id = 1;   -- 900
BEGIN;
UPDATE l10_accounts SET balance = balance + 700 WHERE account_id = 1;
SELECT balance FROM l10_accounts WHERE account_id = 1;   -- 1600
ROLLBACK;
SELECT balance FROM l10_accounts WHERE account_id = 1;   -- 900

-- 3. Незафиксированное изменение не видно другому сеансу
-- Сеанс A
BEGIN;
UPDATE l10_accounts SET balance = balance + 5 WHERE account_id = 1;
SELECT balance FROM l10_accounts WHERE account_id = 1;   -- 905
-- Сеанс B
SELECT balance FROM l10_accounts WHERE account_id = 1;   -- 900
-- Сеанс A
ROLLBACK;

-- 4. READ COMMITTED
-- Сеанс A
BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT balance FROM l10_accounts WHERE account_id = 1;   -- 900
-- Сеанс B
UPDATE l10_accounts SET balance = balance + 5 WHERE account_id = 1;
-- Сеанс A
SELECT balance FROM l10_accounts WHERE account_id = 1;   -- 905
COMMIT;

-- 5. REPEATABLE READ
-- Сеанс A
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT balance FROM l10_accounts WHERE account_id = 1;   -- 905
-- Сеанс B
UPDATE l10_accounts SET balance = balance + 5 WHERE account_id = 1;
-- Сеанс A
SELECT balance FROM l10_accounts WHERE account_id = 1;   -- 905
COMMIT;
SELECT balance FROM l10_accounts WHERE account_id = 1;   -- 910

UPDATE l10_accounts SET balance = 900 WHERE account_id = 1;
SELECT SUM(balance) FROM l10_accounts;                   -- 4550

-- 6. UPDATE ожидает UPDATE
-- Сеанс A
BEGIN;
UPDATE l10_accounts SET balance = balance + 1 WHERE account_id = 1;
-- Сеанс B (ждёт)
UPDATE l10_accounts SET balance = balance + 1 WHERE account_id = 1;
-- Сеанс A: диагностика, в blockers PID сеанса A
SELECT pid, state, wait_event_type, wait_event, pg_blocking_pids(pid) AS blockers
FROM pg_stat_activity
WHERE datname = current_database()
ORDER BY pid;
-- Сеанс A
COMMIT;
-- Сеанс B завершается: UPDATE 1
UPDATE l10_accounts SET balance = 900 WHERE account_id = 1;

-- 7. FOR UPDATE и NOWAIT
-- Сеанс A
BEGIN;
SELECT account_id, balance FROM l10_accounts WHERE account_id = 1 FOR UPDATE;
-- Сеанс B: сразу ошибка could not obtain lock on row
BEGIN;
SET LOCAL lock_timeout = '2s';
SELECT account_id FROM l10_accounts WHERE account_id = 1 FOR UPDATE NOWAIT;
ROLLBACK;
-- Сеанс A
ROLLBACK;

-- 8. Deadlock
-- Сеанс A
BEGIN;
UPDATE l10_accounts SET balance = balance + 1 WHERE account_id = 1;
-- Сеанс B
BEGIN;
UPDATE l10_accounts SET balance = balance + 1 WHERE account_id = 2;
-- Сеанс A (ждёт B)
UPDATE l10_accounts SET balance = balance + 1 WHERE account_id = 2;
-- Сеанс B: ERROR deadlock detected
UPDATE l10_accounts SET balance = balance + 1 WHERE account_id = 1;
-- Сеансы A и B
ROLLBACK;

-- 9. Очередь задач, SKIP LOCKED (дополнительно)
-- Сеанс A
BEGIN;
WITH picked AS (
  SELECT task_id FROM l10_tasks WHERE status = 'new' ORDER BY task_id
  FOR UPDATE SKIP LOCKED LIMIT 1
)
UPDATE l10_tasks t SET status = 'running'
FROM picked p WHERE t.task_id = p.task_id
RETURNING t.task_id, t.status;                  -- 1 | running
-- Сеанс B
BEGIN;
WITH picked AS (
  SELECT task_id FROM l10_tasks WHERE status = 'new' ORDER BY task_id
  FOR UPDATE SKIP LOCKED LIMIT 1
)
UPDATE l10_tasks t SET status = 'running'
FROM picked p WHERE t.task_id = p.task_id
RETURNING t.task_id, t.status;                  -- 2 | running
-- Сеансы A и B
COMMIT;

-- 10. Итоговый контроль
SELECT account_id, balance FROM l10_accounts ORDER BY account_id;  -- 900, 600, 2000, 750, 300
SELECT SUM(balance) FROM l10_accounts;                              -- 4550
SELECT pid, state FROM pg_stat_activity
WHERE datname = current_database() AND state LIKE 'idle in transaction%';  -- 0 строк
