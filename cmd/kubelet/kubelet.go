/*
Copyright 2014 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// The kubelet binary is responsible for maintaining a set of containers on a particular host VM.
// It syncs data from both configuration file(s) as well as from a quorum of etcd servers.
// It then communicates with the container runtime (or a CRI shim for the runtime) to see what is
// currently running.  It synchronizes the configuration data, with the running set of containers
// by starting or stopping containers.
package main

import (
	"fmt"
	"os"
	"path/filepath"

	"k8s.io/component-base/cli"
	_ "k8s.io/component-base/logs/json/register"          // for JSON log format registration
	_ "k8s.io/component-base/metrics/prometheus/clientgo" // for client metric registration
	_ "k8s.io/component-base/metrics/prometheus/version"  // for version metric registration
	pluginapi "k8s.io/kubelet/pkg/apis/deviceplugin/v1beta1"
	"k8s.io/kubernetes/cmd/kubelet/app"
	"k8s.io/kubernetes/pkg/config"
	"k8s.io/kubernetes/pkg/kubelet"
	"k8s.io/kubernetes/pkg/kubelet/apis/config/v1beta1"
)

func main() {
	path, ok := os.LookupEnv("KUBELET_USERSPACE_ROOT_DIR")
	if !ok {
		fmt.Println("[ERROR] Missing environment variable 'KUBELET_USERSPACE_ROOT_DIR'")
		os.Exit(2)
	}
	normalizedPath, err := filepath.Abs(path)
	if err != nil {
		fmt.Printf("[ERROR] There is something wrong with provided 'KUBELET_USERSPACE_ROOT_DIR', given=%s error=%s\n", path, err)
		os.Exit(2)
	}
	config.UserspaceRootDir = normalizedPath

	v1beta1.DefaultVolumePluginDir = config.UserspaceRootDir + "/kubelet-plugins/volume/exec"
	v1beta1.DefaultPodLogsDir = config.UserspaceRootDir + "/var/log"

	kubelet.DefaultContainerLogsDir = config.UserspaceRootDir + "/var/log"

	pluginapi.DevicePluginPath = config.UserspaceRootDir + "/device-plugins/"
	pluginapi.KubeletSocket = pluginapi.DevicePluginPath + "kubelet.sock"

	command := app.NewKubeletCommand()
	code := cli.Run(command)
	os.Exit(code)
}
