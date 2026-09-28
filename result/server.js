var express = require('express'),
    async = require('async'),
    { Pool } = require('pg'),
    cookieParser = require('cookie-parser'),
    path = require('path'),
    client = require('prom-client'),
    // load environment from .env when present
    dotenv = require('dotenv'),
    app = express(),
    server = require('http').Server(app),
    io = require('socket.io')(server);

client.collectDefaultMetrics();

const requestCounter = new client.Counter({
  name: 'result_http_requests_total',
  help: 'Total request count for the result application',
  labelNames: ['method', 'route']
});

dotenv.config();

var port = process.env.PORT || 4000;
var dbHost = process.env.DB_HOST || 'db';

io.on('connection', function (socket) {

  socket.emit('message', { text : 'Welcome!' });

  socket.on('subscribe', function (data) {
    socket.join(data.channel);
  });
});

// prefer a full DATABASE_URL (Neon) when provided; fall back to local dbHost
var poolConfig = {};
if (process.env.DATABASE_URL) {
  poolConfig.connectionString = process.env.DATABASE_URL;
  // allow self-signed / skip CA verification for quick testing against Neon
  poolConfig.ssl = { rejectUnauthorized: false };
} else {
  poolConfig.connectionString = 'postgres://postgres:postgres@' + dbHost + '/postgres';
  poolConfig.ssl = false;
}

var pool = new Pool(poolConfig);

async.retry(
  {times: 1000, interval: 1000},
  function(callback) {
    pool.connect(function(err, client, done) {
      if (err) {
        console.error("Waiting for db");
      }
      callback(err, client);
    });
  },
  function(err, client) {
    if (err) {
      return console.error("Giving up");
    }
    console.log("Connected to db");
    getVotes(client);
  }
);

function getVotes(client) {
  client.query('SELECT vote, COUNT(id) AS count FROM votes GROUP BY vote', [], function(err, result) {
    if (err) {
      console.error("Error performing query: " + err);
    } else {
      var votes = collectVotesFromResult(result);
      io.sockets.emit("scores", JSON.stringify(votes));
    }

    setTimeout(function() {getVotes(client) }, 1000);
  });
}

function collectVotesFromResult(result) {
  var votes = {a: 0, b: 0};

  result.rows.forEach(function (row) {
    votes[row.vote] = parseInt(row.count);
  });

  return votes;
}

app.use(cookieParser());
app.use(express.urlencoded({ extended: false }));
app.use(express.static(__dirname + '/views'));

app.get('/', function (req, res) {
  requestCounter.labels(req.method, '/').inc();
  res.sendFile(path.resolve(__dirname + '/views/index.html'));
});

app.get('/metrics', async function (req, res) {
  res.set('Content-Type', client.register.contentType);
  res.end(await client.register.metrics());
});

server.listen(port, function () {
  var port = server.address().port;
  console.log('App running on port ' + port);
});
