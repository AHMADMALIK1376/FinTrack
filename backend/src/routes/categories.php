<?php
/** Income and expense categories. */
declare(strict_types=1);

/** GET /api/categories */
function categories_list(array $user): void
{
    json_response(query('SELECT * FROM categories WHERE user_id = ? ORDER BY type, name', [$user['id']]));
}

/** POST /api/categories  { name, type } */
function categories_create(array $user): void
{
    $body = request_body();
    $row = query_one('INSERT INTO categories (user_id, name, type) VALUES (?, ?, ?) RETURNING *',
        [$user['id'], field($body, 'name'), field($body, 'type')]);
    json_response($row, 201);
}

/**
 * PUT /api/categories/{id}  { name }: rename a category (ACC-01, step 3).
 * Only the name changes; income/expense stays, so past balances stay correct.
 * The reserved "Transfer" categories, used by transfer_money(), cannot be renamed.
 */
function categories_update(array $user, int $id): void
{
    $name = trim((string) field(request_body(), 'name'));
    if ($name === '') {
        throw new ApiError(400, 'Type a name for the category.');
    }
    $current = query_one('SELECT name FROM categories WHERE category_id = ? AND user_id = ?', [$id, $user['id']]);
    if ($current === null) {
        throw new ApiError(404, 'Category not found.');
    }
    if ($current['name'] === 'Transfer' || strcasecmp($name, 'Transfer') === 0) {
        throw new ApiError(400, '"Transfer" is used for moving money between accounts, so it can\'t be renamed or reused.');
    }
    try {
        $row = query_one('UPDATE categories SET name = ? WHERE category_id = ? AND user_id = ? RETURNING *', [$name, $id, $user['id']]);
    }
    catch (PDOException $error) {
        if (($error->errorInfo[0] ?? '') === '23505') {
            throw new ApiError(400, "You already have a category called \"$name\".");
        }
        throw $error;
    }
    json_response($row);
}

/** DELETE /api/categories/{id} (refused while transactions use it: DB-02) */
function categories_delete(array $user, int $id): void
{
    if (execute('DELETE FROM categories WHERE category_id = ? AND user_id = ?', [$id, $user['id']]) === 0) {
        throw new ApiError(404, 'Category not found.');
    }
    no_content();
}
