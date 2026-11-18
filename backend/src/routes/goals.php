<?php
/** Savings goals (GOAL-01, GOAL-02). */
declare(strict_types=1);

/** GET /api/goals */
function goals_list(array $user): void
{
    json_response(query('SELECT * FROM savings_goals WHERE user_id = ? ORDER BY deadline NULLS LAST', [$user['id']]));
}

/** POST /api/goals  { goal_name, target_amount, saved_amount?, deadline? } */
function goals_create(array $user): void
{
    $body = request_body();
    $row = query_one(
        'INSERT INTO savings_goals (user_id, goal_name, target_amount, saved_amount, deadline) VALUES (?, ?, ?, ?, ?) RETURNING *',
        [$user['id'], field($body, 'goal_name'), field($body, 'target_amount'), field($body, 'saved_amount') ?? 0, field($body, 'deadline')]);
    json_response($row, 201);
}

/** PATCH /api/goals/{id}/add  { amount }: add savings to a goal (the database refuses going past the target) */
function goals_add(array $user, int $id): void
{
    $body = request_body();
    $row = query_one('UPDATE savings_goals SET saved_amount = saved_amount + ? WHERE goal_id = ? AND user_id = ? RETURNING *',
        [field($body, 'amount'), $id, $user['id']]);
    if ($row === null) {
        throw new ApiError(404, 'Goal not found.');
    }
    json_response($row);
}

/** DELETE /api/goals/{id} */
function goals_delete(array $user, int $id): void
{
    if (execute('DELETE FROM savings_goals WHERE goal_id = ? AND user_id = ?', [$id, $user['id']]) === 0) {
        throw new ApiError(404, 'Goal not found.');
    }
    no_content();
}
