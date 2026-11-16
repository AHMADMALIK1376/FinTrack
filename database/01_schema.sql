-- =====================================================================
-- FinTrack: Personal Finance Management System
-- 01_schema.sql  -  tables, keys and constraints (3NF)
-- Run in pgAdmin 4 (Query Tool) on an empty database named "fintrack".
-- =====================================================================

DROP TABLE IF EXISTS transactions, budgets, savings_goals, categories, accounts, users CASCADE;

-- 1. users: one row per registered user
CREATE TABLE users (
    user_id        SERIAL PRIMARY KEY,
    full_name      VARCHAR(100) NOT NULL,
    email          VARCHAR(150) NOT NULL UNIQUE,
    password_hash  VARCHAR(255) NOT NULL,
    created_at     TIMESTAMP    NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_email_format CHECK (email LIKE '%_@_%._%')
);

-- 2. accounts: bank, cash or wallet accounts owned by a user
CREATE TABLE accounts (
    account_id     SERIAL PRIMARY KEY,
    user_id        INT          NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    account_name   VARCHAR(80)  NOT NULL,
    account_type   VARCHAR(20)  NOT NULL
                   CHECK (account_type IN ('bank', 'cash', 'wallet', 'card')),
    balance        NUMERIC(12,2) NOT NULL DEFAULT 0,
    created_at     TIMESTAMP    NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_account_name_per_user UNIQUE (user_id, account_name)
);

-- 3. categories: income or expense types (Salary, Food, Rent ...)
CREATE TABLE categories (
    category_id    SERIAL PRIMARY KEY,
    user_id        INT          NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    name           VARCHAR(60)  NOT NULL,
    type           VARCHAR(10)  NOT NULL CHECK (type IN ('income', 'expense')),
    CONSTRAINT uq_category_per_user UNIQUE (user_id, name, type)
);

-- 4. transactions: every income or expense entry
CREATE TABLE transactions (
    transaction_id SERIAL PRIMARY KEY,
    account_id     INT           NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
    category_id    INT           NOT NULL REFERENCES categories(category_id) ON DELETE RESTRICT,
    amount         NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    txn_date       DATE          NOT NULL DEFAULT CURRENT_DATE,
    description    VARCHAR(255),
    created_at     TIMESTAMP     NOT NULL DEFAULT NOW()
);

-- 5. budgets: monthly spending limit for one expense category
CREATE TABLE budgets (
    budget_id      SERIAL PRIMARY KEY,
    user_id        INT           NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    category_id    INT           NOT NULL REFERENCES categories(category_id) ON DELETE CASCADE,
    limit_amount   NUMERIC(12,2) NOT NULL CHECK (limit_amount > 0),
    month          DATE          NOT NULL,   -- always the 1st day of the month
    CONSTRAINT chk_month_first_day CHECK (EXTRACT(DAY FROM month) = 1),
    CONSTRAINT uq_budget UNIQUE (user_id, category_id, month)
);

-- 6. savings_goals: a target amount to save by a deadline
CREATE TABLE savings_goals (
    goal_id        SERIAL PRIMARY KEY,
    user_id        INT           NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    goal_name      VARCHAR(100)  NOT NULL,
    target_amount  NUMERIC(12,2) NOT NULL CHECK (target_amount > 0),
    saved_amount   NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (saved_amount >= 0),
    deadline       DATE,
    CONSTRAINT chk_saved_not_over_target CHECK (saved_amount <= target_amount)
);

-- Indexes that keep reports fast
CREATE INDEX idx_txn_account_date ON transactions (account_id, txn_date);
CREATE INDEX idx_txn_category     ON transactions (category_id);
CREATE INDEX idx_accounts_user    ON accounts (user_id);
CREATE INDEX idx_categories_user  ON categories (user_id);
