###
# Search
###

fs = require "fs"
util = require "util"
_ = require "underscore"
express = require "express"
Sequelize = require "sequelize"

# Install Search API handlers to the given ExpressJS app
exports.configureApp = (app, args) ->
    # A handy way to create API reverse proxy middlewares
    # See: https://github.com/nodejitsu/node-http-proxy/issues/180#issuecomment-3677221
    # See: http://stackoverflow.com/a/21663820/390044
    url = require "url"
    httpProxy = require 'http-proxy'
    bodyParser = require('body-parser')
    morgan = require('morgan')
    proxy = httpProxy.createProxyServer {}
    app.enable('trust proxy')

    morgan.token 'json', getJson = (req, res) ->
        esq = null
        if Object.prototype.toString.call(req.body) == "[object Object]"
            esq = _.clone(req.body)
            if esq.aggs and esq.highlight
                delete esq.aggs
                delete esq.highlight

        user = null
        if req.user?
            user = {
                id: req.user.id,
                display_name: req.user.displayName,
                name: req.user.name,
                emails: req.user.emails,
                photos: req.user.photos,
                gender: req.user.gender
            }
        fields = {
            ts: Date.now() / 1000.0,
            millis: Date.now() - req._start,
            time: new Date().toISOString(),
            ip: req.headers['x-forwarded-for'] || req.connection.remoteAddress || req.ip || req.ips,
            url: req._original_url || req.url,
            params: req.params,
            query: req.query,
            method: req.method,
            referer: req.headers.referer,
            user_agent: req.headers['user-agent'],
            content_type: req.headers['content-type'],
            accept_languages: req.headers['accept-language'],
            es: esq,
            user: user
        }
        return JSON.stringify(fields)

    apiProxyMiddlewareFor = (path, target, rewrites) -> (req, res, next) ->
        if req.url.match path
            # rewrite pathname if any rules were specified
            if rewrites?
                newUrl = url.parse req.url
                # Empty query can be particularly slow.
                # We cache it: https://www.elastic.co/guide/en/elasticsearch/reference/1.7/index-modules-shard-query-cache.html
                if req.body and req.body.aggs and not req.body.query
                    if not newUrl.query?
                        newUrl.query = {}
                    newUrl.query.search_type = 'count'
                    newUrl.query.query_cache = 'true'
                for [pathnameRegex, replacement] in rewrites
                    newUrl.pathname = newUrl.pathname.replace pathnameRegex, replacement
                req._original_url = req.url
                req.url = url.format newUrl
            # proxy request to the target
            # restreaming hack from https://github.com/nodejitsu/node-http-proxy/issues/180#issuecomment-97702206
            body = JSON.stringify(req.body)
            req.headers['content-length'] = Buffer.byteLength(body, 'utf8')
            buffer = {}
            buffer.pipe = (dest)->
                process.nextTick ->
                    dest.write(body)
            proxy.web req, res,
                    target: target
                    buffer: buffer
                , (err, req, res) ->
                    res
                        .status 503
                        .send "Elasticsearch service unavailable\n(#{err})"
        else
            next()

    # Reverse proxy for Elasticsearch
    elasticsearchApiPath = /// ^/api/elasticsearch(|/.*)$ ///
    if process.env.ELASTICSEARCH_BASEURL?
        app.use (req, res, next) ->
            req._start = Date.now()
            next()
        app.use(bodyParser.json())

        if process.env.MBSEARCH_LOG_FILE?
            console.log 'INFO: Logging requests at MBSEARCH_LOG_FILE = ' + process.env.MBSEARCH_LOG_FILE
            morgan_opt = {}
            fs = require('fs')
            morgan_opt.stream = fs.createWriteStream(process.env.MBSEARCH_LOG_FILE, {flags: 'a'})
            app.use(morgan(':json', morgan_opt))
        else
            console.log 'WARNING: MBSEARCH_LOG_FILE undefined; not logging.'

        app.use apiProxyMiddlewareFor elasticsearchApiPath, process.env.ELASTICSEARCH_BASEURL, [
            # pathname /api/elasticsearch must be stripped for Elasticsearch
            [/// ^/api/elasticsearch ///, "/"]
        ]

        sequelize = new Sequelize('database', 'username', 'password', {
            dialect: 'sqlite',
            storage: process.env.ELASTICSEARCH_HOME + '/dossier.db'
        })

        Dossier = sequelize.define('dossier', {
            dossier_name:
                type: Sequelize.TEXT
                allowNull: false

            user_id:
                type: Sequelize.TEXT
                allowNull: false

            user_name:
                type: Sequelize.TEXT
                allowNull: false

            query_string:
                type: Sequelize.TEXT
                allowNull: false

            query_title:
                type: Sequelize.TEXT

            query_is_doc:
                type: Sequelize.BOOLEAN
                allowNull: false
                defaultValue: false

        }, {
            indexes: [
                {
                    fields: ['dossier_name']
                },
                {
                    fields: ['query_string']
                },
                {
                    unique: true
                    fields: ['dossier_name', 'query_string']
                }
            ]
        })
        Dossier.sync()

        app.get '/api/dossier/', (req, res, next) ->
            if not req.user or not req.user.id
                res
                    .status 400
                    .send 'You must log in to use the dossier service.'
            else
                Dossier.aggregate 'dossier_name', 'DISTINCT', {plain: false}
                    .then (dnames) ->
                        names = _.pluck dnames, 'DISTINCT'
                        res.send JSON.stringify(names)

        app.get '/api/dossier/by_dossier/', (req, res, next) ->
            if not req.user or not req.user.id
                res
                    .status 400
                    .send 'You must log in to use the dossier service.'
            else
                Dossier.findAll
                    where:
                        dossier_name: req.query.dossier_name
                    order: 'query_string'
                .then (matches) ->
                    results = _.map matches, (item) ->
                        query_string: item.query_string
                        user_name: item.user_name
                        ts_created: item.createdAt
                    res.send JSON.stringify(results)

        app.all '/api/dossier/by_query/', (req, res, next) ->
            if not req.user or not req.user.id
                res
                    .status 400
                    .send 'You must log in to use the dossier service.'
            else
                if req.method == 'POST'

                    query = req.body.query_string
                    selected = req.body.selected_dossier_names
                    unselected = req.body.unselected_dossier_names

                    _.each selected, (nm) ->
                        Dossier.findOrCreate
                            where:
                                dossier_name: nm
                                query_string: query
                            defaults:
                                user_id: req.user.id
                                user_name: req.user.displayName || ''
                                query_title: req.body.query_title || null
                                query_is_doc: req.body.query_is_doc || false

                    _.each unselected, (nm) ->
                        Dossier.destroy
                            where:
                                    dossier_name: nm
                                    query_string: query

                    res.send 'Dossier API works!'
                else
                    Dossier.findAll
                        where:
                            query_string: req.query.query_string
                    .then (matches) ->
                        current_dnames = _.sortBy (_.pluck matches, 'dossier_name'), _.identity
                        Dossier.aggregate 'dossier_name', 'DISTINCT', {plain: false}
                            .then (dnames) ->
                                options = _.map current_dnames, (nm) ->
                                    name: nm
                                    selected: true
                                unselected_names = _.difference (_.pluck dnames, 'DISTINCT'), current_dnames
                                unselected_options = _.map unselected_names, (nm) ->
                                    name: nm
                                    selected: false
                                options = options.concat unselected_options

                                res.send JSON.stringify(options)

    else
        app.all elasticsearchApiPath, (req, res) ->
            res
                .status 503
                .send "Elasticsearch service not configured\n($ELASTICSEARCH_BASEURL environment not set)"

exports.configureRoutes = (app, args) ->
    app.use "/api/search/schema.json", express.static process.env.DDLOG_SEARCH_SCHEMA if process.env.DDLOG_SEARCH_SCHEMA?
    app.get "/api/search/schema.json", (req, res) -> res.json {}

    # expose custom search result templates to frontend
    app.use "/search/template", express.static "#{process.env.DEEPDIVE_APP}/mindbender/search-template"
    # fallback to default template
    app.get "/search/template/*.html", (req, res) ->
        res.redirect "/search/result-template-default.html"

