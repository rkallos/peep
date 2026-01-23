ExUnit.start()
Application.put_env(:peep, :test_storages, [:default, :striped, {CustomStorage, 3}])
Peep.Support.StorageCounter.start()
