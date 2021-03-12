## API Integration with Mailchimp

This application serves as a bridge between a SQL Server-based CRM and the Mailchimp API.

#### Setting up the application

The application needs to be configured with Mailchimp's API key, as well as the connection details for the database. See `/config/config.example.yml`.

It's only built to work with SQL Server and Mailchimp. It performs both a "pull" where it collects new data from Mailchimp into the main person/user/contact table, and a variable number of configurable "pushes" where you can specify a source view or table with some number of timestamps to allow filtering, a destination list on Active Campaign, and any field mapping that's needed.

#### Setting up a 'push' or 'up' sync

Create a new folder with the name of your sync in the `/integrations` folder. This folder needs to contain a config YAML file with the same name as its containing folder, e.g. `/integrations/main/main.yml`. See the example file for what kind of file is expected.

#### Disabling a sync

Add a preceding underscore to the folder name and it will be ignored, e.g. `main/` becomes `_main/`.

#### Running the application

The application comes with its own ruby runner script, this accepts a few flags, such as `--push-only`, `--pull-only`. You can also set log level (the default is info) to capture more detailed debugging info with `--log-level 0`, or disregard the info messages with `--log-level 2` or higher.

#### Configuring the 'down' sync

The application only runs one down sync, and is currently hardcoded to cut off campaigns after a month - you might miss out on the thin end of the infamous long tail. The config file consists of your schema transform from Mailchimp to your local SQL Server database. You can find it in `/config/pull.yml`.

#### Watch this space

The readme is far from complete.
