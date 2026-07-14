package kube

// Detail lookups for one database: the XR, its composed CNPG cluster, and
// helpers the detail page builds on. Conventions documented here come from
// CNPG (the `<cluster>-app` Secret) and lab/04's Composition ("<xr>-pg").

import "context"

// CNPGClusterDetail is a richer view of a CNPG Cluster than the list needs.
type CNPGClusterDetail struct {
	Metadata ObjMeta `json:"metadata"`
	Spec     struct {
		Instances int `json:"instances"`
		Storage   struct {
			Size string `json:"size"`
		} `json:"storage"`
	} `json:"spec"`
	Status struct {
		Phase          string      `json:"phase"`
		ReadyInstances int         `json:"readyInstances"`
		Conditions     []Condition `json:"conditions"`
	} `json:"status"`
}

// GetWorkshopDatabase fetches one XR; a 404 means "no such database" and is
// reported as nil, not as an error.
func (k *Client) GetWorkshopDatabase(ctx context.Context, name string) (*WorkshopDB, error) {
	var db WorkshopDB
	if err := k.get(ctx, xrPath+"/"+name, &db); err != nil {
		if isNotFound(err) {
			return nil, nil
		}
		return nil, err
	}
	return &db, nil
}

// GetCNPGCluster looks up the composed cluster. The composition names it
// "<xr>-pg" (see lab/04's Composition); the plain name is tried second so
// the page also works for hand-made CNPG clusters in the demo namespace.
func (k *Client) GetCNPGCluster(ctx context.Context, xrName string) (*CNPGClusterDetail, string, error) {
	for _, name := range []string{xrName + "-pg", xrName} {
		var c CNPGClusterDetail
		err := k.get(ctx, "/apis/postgresql.cnpg.io/v1/namespaces/demo/clusters/"+name, &c)
		if err == nil {
			return &c, name, nil
		}
		if !isNotFound(err) {
			return nil, xrName + "-pg", err
		}
	}
	return nil, xrName + "-pg", nil
}
