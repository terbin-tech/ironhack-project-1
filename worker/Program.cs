using System;
using System.Data;
using System.Data.Common;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using Newtonsoft.Json;
using Npgsql;
using StackExchange.Redis;

namespace Worker
{
    public class Program
    {
        // The vote app pushes to "votes". The worker moves each vote to "votes:processing"
        // while it stores it, so a crash or a lost connection cannot drop it (the reliable
        // queue pattern from the Redis LMOVE docs). Votes Postgres refuses go to "votes:failed".
        private const string VotesKey = "votes";
        private const string ProcessingKey = "votes:processing";
        private const string FailedKey = "votes:failed";

        public static int Main(string[] args)
        {
            try
            {
                // Fetch configuration from environment variables
                var dbHost = Environment.GetEnvironmentVariable("DB_HOST") ?? "db";
                var dbUsername = Environment.GetEnvironmentVariable("DB_USERNAME") ?? "postgres";
                var dbPassword = Environment.GetEnvironmentVariable("DB_PASSWORD") ?? "postgres";
                var dbName = Environment.GetEnvironmentVariable("DB_NAME") ?? "postgres";

                var redisHost = Environment.GetEnvironmentVariable("REDIS_HOST") ?? "redis";

                // Construct the connection strings; only the parts without the password are logged
                var pgConnectionString = $"Server={dbHost};Username={dbUsername};Password={dbPassword};Database={dbName}";
                Console.WriteLine($"Database connection: Server={dbHost};Username={dbUsername};Database={dbName}");
                var redisConnectionString = redisHost;

                var pgsql = OpenDbConnection(pgConnectionString);
                var redisConn = OpenRedisConnection(redisConnectionString);
                var redis = redisConn.GetDatabase();

                RequeueUnfinished(redis);

                var definition = new { vote = "", voter_id = "" };
                while (true)
                {
                    // Slow down to prevent CPU spike, only query each 100ms
                    Thread.Sleep(100);

                    // Reconnect redis if down
                    if (redisConn == null || !redisConn.IsConnected)
                    {
                        Console.WriteLine("Reconnecting Redis");
                        redisConn = OpenRedisConnection(redisConnectionString);
                        redis = redisConn.GetDatabase();
                    }

                    // Take the oldest vote, keeping it in the processing list until Postgres has it
                    string? json = redis.ListMove(VotesKey, ProcessingKey, ListSide.Left, ListSide.Right);
                    if (json == null)
                    {
                        pgsql = KeepAlive(pgsql, pgConnectionString);
                        continue;
                    }

                    var vote = JsonConvert.DeserializeAnonymousType(json, definition);
                    if (vote == null || string.IsNullOrEmpty(vote.vote))
                    {
                        Console.Error.WriteLine($"Unreadable vote moved to {FailedKey}");
                        MoveToFailed(redis, json);
                        continue;
                    }

                    Console.WriteLine($"Processing vote for '{vote.vote}' by '{vote.voter_id}'");
                    pgsql = StoreVote(pgsql, pgConnectionString, redis, json, vote.voter_id, vote.vote);
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine(ex.ToString());
                return 1;
            }
        }

        // Votes a previous run took but never stored go back to the front of the queue, oldest first.
        private static void RequeueUnfinished(IDatabase redis)
        {
            var requeued = 0;
            while (!redis.ListMove(ProcessingKey, VotesKey, ListSide.Right, ListSide.Left).IsNull)
            {
                requeued++;
            }
            if (requeued > 0)
            {
                Console.WriteLine($"Requeued {requeued} unfinished votes");
            }
        }

        // Stores one vote, reconnecting and retrying until Postgres accepts or rejects it.
        private static NpgsqlConnection StoreVote(NpgsqlConnection connection, string connectionString, IDatabase redis, string json, string voterId, string vote)
        {
            while (true)
            {
                try
                {
                    if (connection.FullState != ConnectionState.Open)
                    {
                        Console.WriteLine("Reconnecting DB");
                        connection.Dispose();
                        connection = OpenDbConnection(connectionString);
                    }

                    InsertVote(connection, voterId, vote);
                    redis.ListRemove(ProcessingKey, json, 1);
                    return connection;
                }
                catch (PostgresException ex) when (!ex.IsTransient && connection.FullState == ConnectionState.Open)
                {
                    // Postgres refused this vote itself (for example a value over 255 characters);
                    // retrying cannot help, and keeping it would block every vote behind it.
                    Console.Error.WriteLine($"Vote by '{voterId}' refused ({ex.SqlState}), moved to {FailedKey}");
                    MoveToFailed(redis, json);
                    return connection;
                }
                catch (Exception ex) when (IsConnectionFailure(ex))
                {
                    // The connection broke or timed out: the vote stays in the processing list
                    // and the next pass reconnects if needed and tries the same vote again.
                    Console.Error.WriteLine($"Storing vote by '{voterId}' failed ({ex.GetType().Name}), retrying");
                    Thread.Sleep(1000);
                }
            }
        }

        private static bool IsConnectionFailure(Exception ex)
            => ex is DbException || ex is InvalidOperationException || ex is SocketException || ex is TimeoutException;

        private static void MoveToFailed(IDatabase redis, string json)
        {
            redis.ListRightPush(FailedKey, json);
            redis.ListRemove(ProcessingKey, json, 1);
        }

        // Keeps an idle connection open; a failure reconnects instead of ending the worker.
        private static NpgsqlConnection KeepAlive(NpgsqlConnection connection, string connectionString)
        {
            try
            {
                using var command = connection.CreateCommand();
                command.CommandText = "SELECT 1";
                command.ExecuteNonQuery();
                return connection;
            }
            catch (Exception ex) when (IsConnectionFailure(ex))
            {
                Console.Error.WriteLine("Database connection lost, reconnecting");
                connection.Dispose();
                return OpenDbConnection(connectionString);
            }
        }

        private static NpgsqlConnection OpenDbConnection(string connectionString)
        {
            NpgsqlConnection connection;

            while (true)
            {
                try
                {
                    connection = new NpgsqlConnection(connectionString);
                    connection.Open();
                    break;
                }
                catch (SocketException)
                {
                    Console.Error.WriteLine("Waiting for db");
                    Thread.Sleep(1000);
                }
                catch (DbException)
                {
                    Console.Error.WriteLine("Waiting for db");
                    Thread.Sleep(1000);
                }
            }

            Console.Error.WriteLine("Connected to db");

            var command = connection.CreateCommand();
            command.CommandText = @"CREATE TABLE IF NOT EXISTS votes (
                                        id VARCHAR(255) NOT NULL,
                                        vote VARCHAR(255) NOT NULL
                                    )";
            command.ExecuteNonQuery();

            return connection;
        }

        private static ConnectionMultiplexer OpenRedisConnection(string hostname)
        {
            // Use IP address to workaround https://github.com/StackExchange/StackExchange.Redis/issues/410
            var ipAddress = GetIp(hostname);
            Console.WriteLine($"Found redis at {ipAddress}");

            while (true)
            {
                try
                {
                    Console.Error.WriteLine("Connecting to redis");
                    return ConnectionMultiplexer.Connect(ipAddress);
                }
                catch (RedisConnectionException)
                {
                    Console.Error.WriteLine("Waiting for redis");
                    Thread.Sleep(1000);
                }
            }
        }

        private static string GetIp(string hostname)
            => Dns.GetHostEntryAsync(hostname)
                .Result
                .AddressList
                .First(a => a.AddressFamily == AddressFamily.InterNetwork)
                .ToString();

        // The votes table has no unique key, so every stored vote is one row (a changed
        // vote adds a row too, as before).
        private static void InsertVote(NpgsqlConnection connection, string voterId, string vote)
        {
            using var command = connection.CreateCommand();
            command.CommandText = "INSERT INTO votes (id, vote) VALUES (@id, @vote)";
            command.Parameters.AddWithValue("@id", voterId);
            command.Parameters.AddWithValue("@vote", vote);
            command.ExecuteNonQuery();
        }
    }
}
